#!/usr/bin/env bash
#
# ledger-backup.sh
#
# Backup diário do banco ledger_prod (PostgreSQL) com upload para S3
# e retenção de 30 dias.
#
# Fluxo: pg_dump -> gzip -> aws s3 cp -> aplica retenção -> log
#
# Exit codes:
#   0  - sucesso
#   1  - erro de configuração / pré-condições (disco, dependências)
#   2  - falha ao obter credencial no Secrets Manager
#   3  - falha no pg_dump ou na compactação
#   4  - falha no upload para S3
#   5  - falha ao aplicar retenção (não impede o backup em si, mas é reportado)
#   6  - já existe uma execução em andamento (lock)

set -uo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO
# ---------------------------------------------------------------------------
readonly DB_HOST="ledger-db.internal.hvt.io"
readonly DB_PORT="5432"
readonly DB_NAME="ledger_prod"
readonly DB_USER="backup_user"

readonly AWS_REGION="us-east-1"
readonly S3_BUCKET="hvt-ledger-backups"
readonly S3_PREFIX="ledger_prod"                # objetos ficam em s3://bucket/ledger_prod/...
readonly SECRET_ID="ledger-prod/backup_user"    # ID/ARN do secret no Secrets Manager

readonly WORKDIR="/var/backups/ledger"
readonly LOGFILE="/var/log/ledger-backup.log"
readonly LOCKFILE="/var/run/ledger-backup.lock"

readonly RETENTION_DAYS=30
readonly MIN_FREE_SPACE_GB=20    # margem de segurança acima do tamanho médio do dump (~12GB)

readonly TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
readonly DUMP_FILE="${WORKDIR}/${DB_NAME}_${TIMESTAMP}.sql"
readonly GZ_FILE="${DUMP_FILE}.gz"
readonly S3_KEY="${S3_PREFIX}/${DB_NAME}_${TIMESTAMP}.sql.gz"

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "[${ts}] [${level}] ${msg}" | tee -a "${LOGFILE}"
}

log_info()  { log "INFO"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# LIMPEZA / TRAP
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    # Remove dump local (comprimido ou não) para não consumir os 80GB do disco
    rm -f "${DUMP_FILE}" "${GZ_FILE}" 2>/dev/null || true
    unset PGPASSWORD
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# LOCK — evita execuções concorrentes (ex.: job anterior ainda rodando)
# ---------------------------------------------------------------------------
exec 200>"${LOCKFILE}"
if ! flock -n 200; then
    log_error "Execução já em andamento (lock ${LOCKFILE} ocupado). Abortando."
    exit 6
fi

log_info "===== Iniciando backup de ${DB_NAME} ====="

# ---------------------------------------------------------------------------
# PRÉ-CONDIÇÕES
# ---------------------------------------------------------------------------
mkdir -p "${WORKDIR}"

for bin in pg_dump gzip aws jq; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        log_error "Dependência ausente: ${bin}. Abortando."
        exit 1
    fi
done

free_gb=$(df --output=avail -BG "${WORKDIR}" | tail -1 | tr -dc '0-9')
if [ "${free_gb}" -lt "${MIN_FREE_SPACE_GB}" ]; then
    log_error "Espaço insuficiente em ${WORKDIR}: ${free_gb}GB livres (mínimo ${MIN_FREE_SPACE_GB}GB). Abortando."
    exit 1
fi
log_info "Espaço livre em disco: ${free_gb}GB (ok)."

# ---------------------------------------------------------------------------
# OBTÉM CREDENCIAL DO SECRETS MANAGER (via IAM role da instância)
# ---------------------------------------------------------------------------
log_info "Buscando credencial do banco no Secrets Manager (${SECRET_ID})..."

SECRET_JSON="$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --region "${AWS_REGION}" \
    --query 'SecretString' \
    --output text 2>>"${LOGFILE}")"

if [ -z "${SECRET_JSON}" ]; then
    log_error "Falha ao obter secret '${SECRET_ID}' do Secrets Manager. Verifique a IAM role da instância."
    exit 2
fi

# Suporta tanto {"password": "..."} quanto string simples
if echo "${SECRET_JSON}" | jq -e . >/dev/null 2>&1; then
    export PGPASSWORD="$(echo "${SECRET_JSON}" | jq -r '.password')"
else
    export PGPASSWORD="${SECRET_JSON}"
fi

if [ -z "${PGPASSWORD}" ] || [ "${PGPASSWORD}" = "null" ]; then
    log_error "Credencial obtida está vazia/inválida. Abortando."
    exit 2
fi
log_info "Credencial obtida com sucesso."

# ---------------------------------------------------------------------------
# DUMP + COMPACTAÇÃO
# ---------------------------------------------------------------------------
log_info "Executando pg_dump em ${DB_HOST}:${DB_PORT}/${DB_NAME}..."

pg_dump \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --dbname="${DB_NAME}" \
    --no-password \
    --format=plain \
    --file="${DUMP_FILE}" 2>>"${LOGFILE}"

pg_dump_status=$?
if [ ${pg_dump_status} -ne 0 ]; then
    log_error "pg_dump falhou com código ${pg_dump_status}."
    exit 3
fi
log_info "pg_dump concluído. Tamanho: $(du -h "${DUMP_FILE}" | cut -f1)."

log_info "Compactando dump com gzip..."
gzip -9 "${DUMP_FILE}" 2>>"${LOGFILE}"
gzip_status=$?
if [ ${gzip_status} -ne 0 ] || [ ! -f "${GZ_FILE}" ]; then
    log_error "Falha na compactação (gzip status ${gzip_status})."
    exit 3
fi

# Testa integridade do gzip antes de subir
if ! gzip -t "${GZ_FILE}" 2>>"${LOGFILE}"; then
    log_error "Arquivo compactado corrompido (falhou em gzip -t)."
    exit 3
fi
log_info "Compactação concluída e íntegra. Tamanho final: $(du -h "${GZ_FILE}" | cut -f1)."

# ---------------------------------------------------------------------------
# UPLOAD PARA S3
# ---------------------------------------------------------------------------
log_info "Enviando para s3://${S3_BUCKET}/${S3_KEY}..."

aws s3 cp "${GZ_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
    --region "${AWS_REGION}" \
    --sse "aws:kms" \
    --only-show-errors 2>>"${LOGFILE}"

upload_status=$?
if [ ${upload_status} -ne 0 ]; then
    log_error "Falha no upload para S3 (status ${upload_status})."
    exit 4
fi

# Confirma que o objeto realmente existe no bucket
if ! aws s3api head-object --bucket "${S3_BUCKET}" --key "${S3_KEY}" --region "${AWS_REGION}" >/dev/null 2>>"${LOGFILE}"; then
    log_error "Objeto não encontrado no S3 após upload (verificação head-object falhou)."
    exit 4
fi
log_info "Upload confirmado: s3://${S3_BUCKET}/${S3_KEY}"

# ---------------------------------------------------------------------------
# RETENÇÃO — remove objetos com mais de N dias
# ---------------------------------------------------------------------------
log_info "Aplicando política de retenção (${RETENTION_DAYS} dias)..."

retention_errors=0
cutoff_epoch=$(date -u -d "-${RETENTION_DAYS} days" +%s)

# Lista objetos do prefixo e avalia LastModified
# NOTA: usamos process substitution (< <(...)) em vez de pipe para que o
# incremento de retention_errors dentro do while NÃO ocorra em subshell —
# um pipe (cmd | while ...) faria o while rodar em subshell e a variável
# se perderia ao final do loop, mascarando falhas de remoção.
while IFS=$'\t' read -r key last_modified; do
    [ -z "${key}" ] && continue
    obj_epoch=$(date -u -d "${last_modified}" +%s 2>/dev/null) || continue
    if [ "${obj_epoch}" -lt "${cutoff_epoch}" ]; then
        log_info "Removendo backup expirado: ${key} (LastModified: ${last_modified})"
        if ! aws s3 rm "s3://${S3_BUCKET}/${key}" --region "${AWS_REGION}" >>"${LOGFILE}" 2>&1; then
            log_error "Falha ao remover ${key}"
            retention_errors=$((retention_errors + 1))
        fi
    fi
done < <(aws s3api list-objects-v2 \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}/" \
    --region "${AWS_REGION}" \
    --query 'Contents[].[Key,LastModified]' \
    --output text 2>>"${LOGFILE}")

if [ "${retention_errors}" -gt 0 ]; then
    log_error "Retenção concluída com ${retention_errors} erro(s) de remoção."
    log_info "===== Backup CONCLUÍDO (com avisos de retenção) ====="
    exit 5
fi

log_info "Retenção aplicada com sucesso."
log_info "===== Backup CONCLUÍDO COM SUCESSO ====="
exit 0
