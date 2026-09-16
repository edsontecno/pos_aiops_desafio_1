# Questao 2

## Prompt:

```
#ROLE
Você é um arquiteto cloud/SRE com mais de 20 anos de expirência em AWS.

#TAREFA
Realize a criação de uma cron diária para realizar backup de um banco de dados. O script precisa fazer o dump com pg_dump, compactar com gzip, subir o arquivo pro bucket S3 hvt-ledger-backups via aws s3 cp, manter 30 dias de retenção no S3 (removendo os mais antigos), registrar cada execução em /var/log/ledger-backup.log com timestamp, e sair com exit code adequado em caso de falha. O ambiente está nas seguintes condições:

#Ambiente
Host: ledger-db.internal.hvt.io
Porta: 5432
Banco: ledger_prod
Usuário de backup: backup_user
Senha: variável de ambiente PGPASSWORD, populada pelo AWS Secrets Manager via IAM role da instância
Região AWS: us-east-1
SO da instância: Ubuntu 22.04 LTS
Diretório de trabalho com 80 GB livres: /var/backups/ledger
Tamanho médio atual do dump compactado: ~12 GB

#Format
A resposta deve incluir o script bash completo para o backup, entrada cron para job e documentação clar de como a implantação deve ser realizada.
```

## Modelo

Claude Sonnet 5: escolhido por equilibrar qualidade técnica e custo em tarefas de automação operacional.

## Output:

```
Backup Automatizado PostgreSQL → S3 (ledger_prod)

Vou entregar três arquivos: o script de backup, a definição do cron job, e a documentação de implantação — incluindo alguns pontos críticos de robustez que vale destacar antes do código.

Atenção a um detalhe importante do seu ambiente: você descreveu PGPASSWORD como uma variável de ambiente "populada pelo AWS Secrets Manager via IAM role da instância". Na prática, isso normalmente significa que algum processo (user-data, systemd EnvironmentFile, etc.) exporta essa variável na sessão — mas cron não herda o ambiente de shells interativos nem de scripts de bootstrap. Se o job cron simplesmente assumir que PGPASSWORD já está setada, ele vai falhar silenciosamente em produção mesmo funcionando no teste manual.

Por isso, fiz o script buscar a credencial diretamente do Secrets Manager em tempo de execução (usando a IAM role da instância), o que é mais robusto e é a prática recomendada de qualquer forma (nunca depender de env var persistida em disco). Documentei essa decisão no deploy guide, incluindo a alternativa caso vocês já tenham um mecanismo de injeção validado.

Pontos que valem destaque além do código:

Credencial via Secrets Manager em runtime, não via env var herdada — cron não propaga variáveis de sessão, então o script busca PGPASSWORD diretamente a cada execução usando a IAM role da instância.
Lock com flock — evita duas execuções concorrentes se um backup atrasar.
Verificação de integridade do gzip (gzip -t) antes do upload, e head-object depois do upload para confirmar que o S3 realmente recebeu o arquivo.
Retenção implementada com process substitution (< <(...)), não com pipe — um detalhe que evita um bug clássico de bash onde o while roda em subshell e perde a contagem de erros.
Exit codes diferenciados por etapa (dump, upload, retenção) para facilitar troubleshooting/alertas.

No DEPLOY.md cobri a policy IAM mínima, criação de usuário de serviço dedicado, teste de restauração e sugestões de alerta — já que exit code sem monitoramento downstream não avisa ninguém sozinho.
```

Arquivos gerados em `files/`:

| Arquivo                                              | Descrição                                                                                           |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [files/ledger-backup.sh](files/ledger-backup.sh)     | Script bash completo: pg_dump, gzip, upload S3, retenção de 30 dias, logging e exit codes por etapa |
| [files/ledger-backup-cron](files/ledger-backup-cron) | Entrada cron (`/etc/cron.d/`) para execução diária às 03:00 UTC como usuário `ledgerbackup`         |
| [files/DEPLOY.md](files/DEPLOY.md)                   | Documentação de implantação: IAM, usuário de serviço, instalação, testes e observabilidade          |

## Justificativa

O prompt segue o framework RTF (Role, Task, Format): na Role foi definida a persona de arquiteto cloud/SRE com experiência em AWS; na Task foram especificados o fluxo completo do backup (pg_dump, gzip, S3, retenção, log e exit codes) e o ambiente operacional; no Format foi exigida a entrega do script bash, da entrada cron e da documentação de deploy.

Observação: o modelo ampliou o escopo além do enunciado ao buscar a credencial diretamente no Secrets Manager em runtime (em vez de assumir `PGPASSWORD` no ambiente do cron) e ao incluir lock com `flock`, verificação de integridade do gzip e sugestões de observabilidade — decisões tecnicamente sólidas, mas não solicitadas explicitamente no prompt.
