# Questao 4

## Prompt:

```
# TASK
Crie um relatório sobre crescimento de transações nos últimos 6 meses.

#Action
Faça uma análise da estrutura de tabela abaixo sabendo as seguintes informações

Categorias em produção hoje: subscription, one_time, refund e credit_adjustment. Só entra no relatório quem tem status = 'completed'. O campo amount_cents está em centavos de real e precisa aparecer na saída em reais com 2 casas decimais

CREATE TABLE transactions (
  id              BIGSERIAL PRIMARY KEY,
  customer_id     BIGINT NOT NULL REFERENCES customers(id),
  category        VARCHAR(32) NOT NULL,
  amount_cents    BIGINT NOT NULL,
  status          VARCHAR(16) NOT NULL,
  payment_method  VARCHAR(16),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ
);

CREATE INDEX idx_transactions_created_at ON transactions(created_at);
CREATE INDEX idx_transactions_status ON transactions(status);
CREATE INDEX idx_transactions_category ON transactions(category);

CREATE TABLE customers (
  id          BIGSERIAL PRIMARY KEY,
  segment     VARCHAR(16) NOT NULL,
  country     CHAR(2) NOT NULL,
  signup_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

#Goal

Gere um sql que retorne a seguinte informação: um recorte dos últimos 6 meses corridos a partir de hoje (2026-09-16), agrupado por mês (no formato YYYY-MM) e por categoria, trazendo duas métricas por linha: quantidade de transações e volume total em reais. Ordenação final: mês crescente, depois categoria crescente.


```

## Modelo

Claude Sonnet 5 — preciso em SQL com filtros, agrupamento e conversão de valores.

## Output:

Para atender ao seu objetivo com precisão e excelente performance, a consulta SQL deve aplicar os filtros diretamente nas datas de conclusão (completed_at), fazer o agrupamento pelas colunas calculadas e realizar a conversão de centavos para reais.

Pontos de atenção na estrutura atual:

Filtro de Data: O relatório analisa transações finalizadas (status = 'completed'). Por isso, a filtragem dos últimos 6 meses e o agrupamento mensal utilizam o campo completed_at em vez de created_at.

Conversão de Valores: O valor é dividido por 100.0 para converter centavos em reais, mantendo as casas decimais.

```
SELECT
  TO_CHAR(completed_at, 'YYYY-MM') AS mes,
  category AS categoria,
  COUNT(id) AS quantidade_transacoes,
  ROUND(SUM(amount_cents) / 100.0, 2) AS volume_total_reais
FROM transactions
WHERE status = 'completed'
  AND completed_at >= '2026-09-16'::timestamptz - INTERVAL '6 months'
  AND completed_at <= '2026-09-16'::timestamptz
GROUP BY
  TO_CHAR(completed_at, 'YYYY-MM'),
  category
ORDER BY
  mes ASC,
  categoria ASC;
```

## Justificativa

O prompt segue a estrutura Task / Action / Goal: na Task foi definido o objetivo de gerar um relatório sobre crescimento de transações nos últimos 6 meses; na Action foram fornecidos o schema das tabelas e demais regras do banco de dados; no Goal foi especificado o recorte temporal (6 meses a partir de 2026-09-16), o agrupamento por mês (`YYYY-MM`) e por categoria, as métricas de quantidade e volume, e a ordenação final.
