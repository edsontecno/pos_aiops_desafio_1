# Questao 3

## Prompt:

```
# Task
Crie um relatório de redução de custo da cloud até o fim do período, sem degradar SLA.

# Action
Faça uma análise de custo dos recursos da nuvem abaixo e classifique do mais caro para o mais barato

servico,categoria,custo_mensal_usd,uso_medio_pct,observacao
EC2 reservada,compute,4200,72,contrato de 1 ano
EC2 on-demand,compute,8200,45,workloads variaveis
EKS,compute,6700,58,3 clusters
RDS PostgreSQL,databases,8200,62,multi-AZ
ElastiCache Redis,databases,2100,40,cluster de producao
S3 Standard,storage,3100,,5 buckets principais
EBS gp3,storage,1600,68,volumes de producao
CloudWatch Logs,observability,2800,,retencao de 90 dias
CloudWatch Metrics,observability,900,,
Data Transfer Out,network,1900,,trafego entre regioes
NAT Gateway,network,1200,,3 gateways ativos
Lambda,compute,900,30,~12M invocacoes/mes

# Goal
Objetivo: gerar um relatório em formato markdown com uma tabela com o seguinte template

Oportunidades priorizadas - percentual de redução - total de esforço (baixo, médio, alto) - riscos - pré-requisitos (se existir)
```

## Modelo

Gemini Flash 3.6 — rápido para análise de custos e relatório em markdown.

## Output:

# Relatório de Análise e Otimização de Custos de Cloud

## 1. Análise Atual de Custos (Classificado do mais caro para o mais barato)

A soma total dos custos mensais atuais da infraestrutura é de **$41.800,00 USD**.

| Posição | Serviço            | Categoria     | Custo Mensal (USD) | Uso Médio (%) | Observação            |
| ------- | ------------------ | ------------- | ------------------ | ------------- | --------------------- |
| 1       | EC2 on-demand      | Compute       | $8.200             | 45%           | Workloads variáveis   |
| 2       | RDS PostgreSQL     | Databases     | $8.200             | 62%           | Multi-AZ              |
| 3       | EKS                | Compute       | $6.700             | 58%           | 3 clusters            |
| 4       | EC2 reservada      | Compute       | $4.200             | 72%           | Contrato de 1 ano     |
| 5       | S3 Standard        | Storage       | $3.100             | -             | 5 buckets principais  |
| 6       | CloudWatch Logs    | Observability | $2.800             | -             | Retenção de 90 dias   |
| 7       | ElastiCache Redis  | Databases     | $2.100             | 40%           | Cluster de produção   |
| 8       | Data Transfer Out  | Network       | $1.900             | -             | Tráfego entre regiões |
| 9       | EBS gp3            | Storage       | $1.600             | 68%           | Volumes de produção   |
| 10      | NAT Gateway        | Network       | $1.200             | -             | 3 gateways ativos     |
| 11      | CloudWatch Metrics | Observability | $900               | -             | -                     |
| 12      | Lambda             | Compute       | $900               | 30%           | ~12M invocações/mês   |

---

## 2. Plano de Ação e Oportunidades Priorizadas

A tabela abaixo apresenta as estratégias de otimização focadas na redução de custos mantendo integralmente a garantia dos SLAs operacionais.

| Oportunidades Priorizadas                                                                                                                | Percentual de Redução Est.                                          | Total de Esforço | Riscos                                                                               | Pré-requisitos                                                                                           |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| **Otimização de EC2 On-Demand** (Migração parcial para Savings Plans / Reserved Instances ou Karpenter/Spot para workloads não-críticos) | 30% - 40% (Economia de ~$2.500/mês)                                 | Médio            | Flutuação de capacidade se usado Spot em workloads incompatíveis.                    | Mapeamento detalhado de sazonalidade e perfis de uso de CPU/Memória das instâncias.                      |
| **Ajuste de Retenção e Otimização do CloudWatch Logs** (Reduzir retenção padrão para 30 dias e exportar logs antigos para S3 Glacier)    | 40% - 60% (Economia de ~$1.400/mês)                                 | Baixo            | Ligeiro atraso na consulta de logs antigos (históricos armazenados no S3).           | Aprovação da equipe de Compliance/Segurança para alteração das políticas de retenção.                    |
| **Otimização de Armazenamento S3** (Implementação de S3 Lifecycle Policies - Transition para Infrequent Access/Glacier)                  | 25% - 35% (Economia de ~$900/mês)                                   | Baixo            | Latência aumentada para recuperação de objetos antigos/raros.                        | Mapeamento dos padrões de acesso aos objetos nos 5 buckets principais.                                   |
| **Direcionamento e Otimização do RDS PostgreSQL** (Right-sizing de instâncias e migração para Reserved Instances de 1 ou 3 anos)         | 20% - 30% (Economia de ~$2.000/mês)                                 | Baixo            | Nenhum (para compra de RIs). Pequena janela de manutenção se for feito right-sizing. | Análise de métricas de IOPS, CPU e memória do banco de dados em horários de pico.                        |
| **Consolidação/Right-sizing do EKS e Node Groups** (Autoscaling eficiente com Karpenter/Cluster Autoscaler e revisão dos 3 clusters)     | 15% - 25% (Economia de ~$1.300/mês)                                 | Alto             | Instabilidade momentânea durante o remanejamento e draining dos nós.                 | Cobertura robusta de testes de carga e especificação correta de Resource Requests/Limits nas aplicações. |
| **Right-sizing e Ajuste de Nós do ElastiCache Redis** (Revisão da capacidade e utilização de CPU/Memória que está em 40%)                | 20% - 30% (Economia de ~$500/mês)                                   | Médio            | Breve tempo de failover durante o ajuste de tamanho do cluster.                      | Garantir que o cluster suporte o limite máximo de memória com folga após a redução.                      |
| **Arquitetura de Rede e NAT Gateway** (VPC Endpoints para serviços AWS e revisão do tráfego entre zonas de disponibilidade)              | 15% - 25% (Economia de ~$300/mês no NAT + redução no Data Transfer) | Médio            | Alteração em rotas de VPC e tabelas de roteamento.                                   | Auditoria de rotas de saída de tráfego e serviços AWS mais consumidos pelas aplicações.                  |

---

## 3. Resumo de Impacto Esperado

- **Custo Atual:** $41.800,00 USD / mês
- **Economia Estimada Total:** 20% a 30% (~$8.900,00 a $12.500,00 USD / mês)
- **Garantia de SLA:** Todas as estratégias mantêm a alta disponibilidade (Multi-AZ no RDS, capacidade garantida nas workloads de compute essenciais e redundância de rede).

## Justificativa

O prompt segue a estrutura Task / Action / Goal: na Task foi definido o objetivo de gerar um relatório de redução de custo sem degradar SLA; na Action foram fornecidos os dados de custo dos recursos cloud e a instrução de classificá-los do mais caro para o mais barato; no Goal foi especificado o template da tabela de oportunidades (priorização, percentual de redução, esforço, riscos e pré-requisitos).
