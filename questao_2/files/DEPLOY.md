# Implantação — Backup diário `ledger_prod` → S3

## 1. Visão geral

| Item | Valor |
|---|---|
| Origem | PostgreSQL `ledger_prod` em `ledger-db.internal.hvt.io:5432` |
| Destino | `s3://hvt-ledger-backups/ledger_prod/` |
| Frequência | Diária, 03:00 UTC |
| Retenção | 30 dias (aplicada pelo próprio script) |
| Log | `/var/log/ledger-backup.log` |
| Exit codes | `0` sucesso · `1` pré-condição · `2` secret · `3` dump/gzip · `4` upload · `5` retenção · `6` lock |

Arquivos entregues:
- `ledger-backup.sh` — script principal
- `ledger-backup-cron` — definição para `/etc/cron.d/`
- `DEPLOY.md` — este documento

---

## 2. Decisão de design: credencial via Secrets Manager em runtime

Você indicou que `PGPASSWORD` é populada pelo Secrets Manager via IAM role da instância. **Cron não herda variáveis de ambiente de sessões de login nem de scripts de user-data** — só o que estiver no crontab/`/etc/environment`/no próprio script. Duas opções:

- **(Recomendada, já implementada no script)** O script busca o secret diretamente via `aws secretsmanager get-secret-value` a cada execução, usando a IAM role da instância (EC2 Instance Profile). Não depende de nenhuma variável persistida em disco, funciona igual em cron ou execução manual, e a credencial nunca fica gravada em arquivo.
- **Alternativa:** se vocês já têm um mecanismo validado que injeta `PGPASSWORD` no ambiente do processo `cron` (ex.: via `/etc/security/pam_env.conf` ou um `EnvironmentFile` de systemd timer), pode remover o bloco de `get-secret-value` e usar a variável diretamente. Nesse caso, prefira migrar o agendamento de `cron` puro para um **systemd timer** com `EnvironmentFile=`, que tem tratamento de ambiente mais previsível que cron.

Ajuste o valor de `SECRET_ID` no script para o nome/ARN real do secret.

---

## 3. Pré-requisitos na instância

```bash
# Cliente PostgreSQL compatível com a versão do servidor
sudo apt-get update
sudo apt-get install -y postgresql-client jq

# AWS CLI v2 (se ainda não estiver presente)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws --version
```

> Confirme que a versão major do `pg_dump` é igual ou superior à do servidor `ledger_prod`. `pg_dump` de versão inferior à do servidor pode falhar ou gerar dump incompleto.

---

## 4. Usuário de serviço dedicado

Não rode o backup como `root` nem como um usuário de login humano.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin ledgerbackup
sudo mkdir -p /var/backups/ledger
sudo chown ledgerbackup:ledgerbackup /var/backups/ledger
sudo chmod 700 /var/backups/ledger

sudo touch /var/log/ledger-backup.log
sudo chown ledgerbackup:ledgerbackup /var/log/ledger-backup.log
sudo chmod 640 /var/log/ledger-backup.log
```

---

## 5. IAM Role da instância (EC2 Instance Profile)

Anexe (ou edite) a role da instância com uma policy restrita aos recursos necessários — evite `s3:*` ou `secretsmanager:*` amplos:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LedgerBackupS3",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::hvt-ledger-backups",
        "arn:aws:s3:::hvt-ledger-backups/ledger_prod/*"
      ]
    },
    {
      "Sid": "LedgerBackupSecret",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:ledger-prod/backup_user-*"
    },
    {
      "Sid": "LedgerBackupKMS",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:us-east-1:<ACCOUNT_ID>:key/<KMS_KEY_ID>"
    }
  ]
}
```

- O bloco `LedgerBackupKMS` só é necessário se o secret **ou** o bucket usar uma chave KMS gerenciada pelo cliente (CMK). Se o bucket usar `SSE-S3` (`aws:kms` com chave padrão da AWS), ajuste o parâmetro `--sse` no script para `AES256` e remova esse statement.
- Substitua `<ACCOUNT_ID>` e `<KMS_KEY_ID>`.

No lado do bucket `hvt-ledger-backups`, garanta:
- **Versionamento habilitado** (proteção extra contra sobrescrita/exclusão acidental).
- **Bucket policy** negando acesso público e, idealmente, exigindo `aws:SecureTransport`.
- Considerar **Object Lock (modo governance)** para os objetos de backup, dado que é um ledger — isso impede exclusão mesmo por credenciais comprometidas dentro da janela de retenção legal.

---

## 6. Banco de dados

Confirme que `backup_user` tem apenas os privilégios necessários para dump (idealmente role `pg_read_all_data` ou equivalente, **sem** privilégios de escrita):

```sql
-- Exemplo mínimo (ajustar ao modelo de roles já existente)
GRANT CONNECT ON DATABASE ledger_prod TO backup_user;
GRANT pg_read_all_data TO backup_user;
```

O secret no Secrets Manager (`ledger-prod/backup_user`) deve conter, no mínimo:
```json
{ "password": "<senha-do-backup_user>" }
```
(o script também aceita o secret como string simples, sem JSON.)

---

## 7. Instalação do script e do cron

```bash
sudo cp ledger-backup.sh /usr/local/bin/ledger-backup.sh
sudo chown root:root /usr/local/bin/ledger-backup.sh
sudo chmod 755 /usr/local/bin/ledger-backup.sh

sudo cp ledger-backup-cron /etc/cron.d/ledger-backup
sudo chmod 644 /etc/cron.d/ledger-backup
sudo systemctl restart cron
```

Edite `/usr/local/bin/ledger-backup.sh` e ajuste, se necessário:
- `SECRET_ID`
- `S3_PREFIX` (se quiser um layout de path diferente)
- Horário no arquivo `/etc/cron.d/ledger-backup`

---

## 8. Teste manual antes de confiar no agendamento

```bash
sudo -u ledgerbackup /usr/local/bin/ledger-backup.sh
echo "exit code: $?"
tail -n 50 /var/log/ledger-backup.log
```

Verificações pós-teste:
```bash
# Confirma que o objeto chegou no S3
aws s3 ls s3://hvt-ledger-backups/ledger_prod/ --region us-east-1

# Baixa e valida integridade do gzip sem restaurar
aws s3 cp s3://hvt-ledger-backups/ledger_prod/<arquivo>.sql.gz /tmp/ --region us-east-1
gzip -t /tmp/<arquivo>.sql.gz && echo "arquivo íntegro"
```

**Teste de retenção:** antes de ir para produção, crie objetos de teste no bucket com `LastModified` simulando >30 dias (ou rode o script com `RETENTION_DAYS=0` temporariamente em um bucket de teste) para confirmar que a remoção funciona como esperado, já que exclusão em produção é irreversível sem Object Lock/versionamento.

---

## 9. Rotação do log local

O `/var/log/ledger-backup.log` cresce indefinidamente sem rotação. Adicione:

```bash
sudo tee /etc/logrotate.d/ledger-backup <<'EOF'
/var/log/ledger-backup.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ledgerbackup ledgerbackup
}
EOF
```

---

## 10. Observabilidade e alertas (recomendado, não incluso no script)

O script sai com exit code adequado, mas **cron por si só não alerta ninguém** em caso de falha. Sugestões, em ordem de esforço crescente:

1. **Mínimo:** definir `MAILTO` no cron para um endereço monitorado (requer MTA configurado na instância).
2. **Recomendado:** publicar uma métrica customizada no CloudWatch ao final do script (`aws cloudwatch put-metric-data --namespace LedgerBackup --metric-name BackupSuccess --value 0|1`) e criar um alarme para "sem sucesso nas últimas 26h".
3. **Mais robusto:** configurar uma regra EventBridge que dispare se **nenhum objeto novo** aparecer no prefixo `ledger_prod/` do bucket em 24h (S3 Event Notifications + Lambda, ou CloudWatch Metrics de S3 Storage Lens).

---

## 11. Plano de restauração (não esquecer de testar)

Backup sem teste de restore não é backup confiável. Periodicamente:

```bash
aws s3 cp s3://hvt-ledger-backups/ledger_prod/<arquivo>.sql.gz - | gunzip | \
  psql -h <host-restore-teste> -U <usuario> -d <banco-teste>
```

Recomenda-se automatizar esse teste (ex.: mensal, em uma instância RDS/EC2 efêmera) e documentar o RTO/RPO resultante.
