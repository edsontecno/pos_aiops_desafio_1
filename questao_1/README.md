# Questao 1

## Prompt:

```
#ROLE
Você é um arquiteto cloud especialista em realizar a preparação de projetos para containers.

#TAREFA
Crie um Dockerfile para um projeto que possui as seguintes características:

#Estrutura do projeto
lift/
├── app.py
├── requirements.txt
├── lib/
│ ├── auth.py
│ └── storage.py
└── tests/
└── test_app.py

#Arquivo requirements
Dependências do projeto
Flask==3.0.0
gunicorn==21.2.0
requests==2.31.0
python-dotenv==1.0.0
psycopg2-binary==2.9.9

- Em produção o serviço sobe com gunicorn --bind 0.0.0.0:8080 --workers 4 app:app.
- Duas variáveis de ambiente que precisam estar presentes no runtime DATABASE_URL e API_KEY
- Porta 8080

#Format
Dockerfile seguindo os padrões de mercado, utilizando muiltstage build para otimizar a imagem final
```

## Modelo

Claude Sonnet 5.

## Output:

```
# ============================================================

# Stage 1: Build - instala dependências em um virtualenv isolado

# ============================================================

FROM python:3.12-slim AS builder

# Evita geração de arquivos .pyc e força output sem buffer

ENV PYTHONDONTWRITEBYTECODE=1 \
 PYTHONUNBUFFERED=1 \
 PIP_NO_CACHE_DIR=1 \
 PIP_DISABLE_PIP_VERSION_CHECK=1

# Dependências de sistema necessárias apenas para compilar psycopg2-binary

# (libpq-dev + build-essential na build stage; runtime só precisa da lib compartilhada)

RUN apt-get update && apt-get install -y --no-install-recommends \
 build-essential \
 libpq-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cria virtualenv para isolar dependências e facilitar cópia entre stages

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copia apenas requirements primeiro para aproveitar cache de camadas

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ============================================================

# Stage 2: Runtime - imagem final enxuta, sem ferramentas de build

# ============================================================

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
 PYTHONUNBUFFERED=1 \
 PATH="/opt/venv/bin:$PATH"

# Apenas a lib de runtime do postgres (sem headers/compiladores)

RUN apt-get update && apt-get install -y --no-install-recommends \
 libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system app && useradd --system --gid app --no-create-home app

WORKDIR /app

# Copia o virtualenv já construído da stage anterior

COPY --from=builder /opt/venv /opt/venv

# Copia o código-fonte da aplicação (respeitando .dockerignore para excluir tests/, .git, etc.)

COPY app.py .
COPY lib/ ./lib/

# Ajusta permissões e roda como usuário não-root

RUN chown -R app:app /app
USER app

# Variáveis de ambiente obrigatórias em runtime.

# Sem valor default proposital: se não forem passadas no `docker run -e` /

# orquestrador, a aplicação deve falhar de forma explícita ao iniciar.

ENV DATABASE_URL="" \
 API_KEY=""

EXPOSE 8080

# Healthcheck básico (ajuste o endpoint conforme sua aplicação exponha um /health)

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
 CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "4", "app:app"]
```

## Justificativa

O prompt segue o framewordk RTF (Role,Task,Format ), na role foi definido a persona de arquiteto cloud, em tarefa foi descrito o que deveria ser feito (no caso o dockerfile com suas características ) e em Format foi definido o formato desejado com multistage.
Observação: o modelo incluiu um `HEALTHCHECK` apontando para `/health` sem que isso tenha sido solicitado no enunciado; como o endpoint não foi especificado, isso pode quebrar a imagem em runtime e, se fosse exigido no prompt, limitaria ainda mais o escopo da tarefa.
