# Questao 8

## Prompt:

```
ROLE
Você é um engheiro SRE com mais de 20 anos de experiência. Você está apoiando
um incidente em andamento durante pico de tráfego e seu relatório será lido em uma call de decisão
que precisa concluir em 20 minutos.

INPUT
Abaixo estão os artefatos coletados durante o incidente. Não presuma nada que não esteja neles.

[Evento de deploy]
Deploy chronos-api: v2.47.0 -> v2.48.0
Argo CD sync: 2026-04-23 18:42:11 UTC
Changelog:
- Adicionado endpoint POST /v2/transactions/batch
- Refatorado cliente do Ledger (pool de conexoes movido para nova biblioteca interna)
- Bump de psycopg 3.1.18 -> 3.2.0
- Reduzido timeout do Ledger de 5s para 2s

[Métricas Beacon - últimos 30 min]
timestamp                p99_latency_ms   req_rate_s   err_rate_pct
2026-04-24 13:30 UTC     420              1200         0.2
2026-04-24 13:45 UTC     510              1450         0.3
2026-04-24 14:00 UTC     780              1780         0.8
2026-04-24 14:10 UTC     2400             2100         4.5
2026-04-24 14:15 UTC     5200             2400         8.2
2026-04-24 14:20 UTC     8100             2650         11.7

[Log - pod chronos-api-79c4d8b9-xk2jp]
2026-04-24 14:19:48 [ERROR] [ledger-client] connection pool exhausted (max=20, active=20, waiting=147)
2026-04-24 14:19:49 [WARN]  [ledger-client] query timeout after 2000ms: SELECT ... FROM transactions WHERE ...
2026-04-24 14:19:49 [ERROR] [handler] POST /v2/transactions/batch failed: context deadline exceeded
2026-04-24 14:19:50 [ERROR] [ledger-client] connection reset by peer
2026-04-24 14:19:51 [WARN]  [circuit-breaker] ledger-client OPEN (threshold 50%, current 87%)
2026-04-24 14:19:52 [ERROR] [reactor] failed to publish message: chronos-api upstream error

[Fila Reactor - chronos-transactions]
- 50.127 mensagens acumuladas, crescendo a ~800/min
- Consumer lag atual: 18 minutos e aumentando

[Estado do cluster]
- Chronos: 12/12 pods running (HPA no máximo)
- CPU médio dos pods: 62%
- Memória média dos pods: 71%
- Conexões ativas ao Ledger: 240/250 (limite do RDS)

STEPS
Siga esta sequência de raciocínio, mostrando o encadeamento lógico entre as evidências:

1. Construa uma linha do tempo correlacionando o horário do deploy (18:42 UTC de ontem)
   com o início da degradação nas métricas — determine se há uma janela de latência entre
   deploy e sintoma, ou se a degradação é abrupta e recente (o que indicaria gatilho de
   tráfego/capacidade em vez de causa direta do deploy).
2. Formule a(s) hipótese(s) de causa raiz cruzando o changelog (novo pool de conexões,
   timeout reduzido de 5s para 2s, bump de psycopg) com os sintomas no log (pool exhausted,
   timeouts, circuit breaker aberto) e com o fato de CPU/memória NÃO estarem saturadas
   (62%/71%) apesar do HPA estar no teto — isso descarta ou não um problema puramente de
   capacidade computacional?
3. Avalie separadamente se o gargalo de 240/250 conexões no RDS é causa primária ou
   consequência (ex.: conexões presas por timeout agressivo/erro no novo cliente do Ledger
   não sendo liberadas corretamente).
4. Para cada opção de mitigação, avalie explicitamente se ela ataca a causa raiz ou apenas
   um sintoma, e o tempo estimado de efeito e o risco de cada uma:
   a) Rollback para v2.47.0
   b) Scaling emergencial (aumento de limits do RDS e do pool de conexões)
5. Avalie o impacto do backlog na fila chronos-transactions (50k+ mensagens, lag de 18 min
   e crescendo) em cada cenário de mitigação — a fila continuará crescendo mesmo após a
   ação escolhida? Por quanto tempo?
6. Formule uma recomendação clara com justificativa baseada em evidência, incluindo o que
   fazer SE a ação recomendada não resolver em X minutos (plano B).

EXPECTATION
Produza um postmortem técnico em Markdown, em português, com esta estrutura fixa:

- Recomendação frase simples
- Timeline resumida contendo horário, evento e métrica relevante
- Causa raiz com níveis (alta/média/baixa) com evidência
- Por que rollback resolveria (ou não) — no máximo 5 opções
- Por que scaling resolveria (ou não) — no máximo 5 opções
- Impacto atual e projetado (fila, latência, erro)
- Plano de ação imediato
- Riscos da ação recomendada e opção de contorno

Seja objetivo: priorize a exatidão técnica em vez da completude, pois o documento será lido em minutos. Todas as afirmações devem se basear estritamente nos materiais fornecidos, citando dados brutos apenas quando necessário para justificar um ponto
```

## Modelo

Sonnet 5 — bom para correlacionar evidências e recomendar ação em incidente.

## Output:

# Postmortem — Degradação chronos-api (2026-04-24)

## Recomendação

**Fazer rollback imediato para v2.47.0 com restart forçado dos pods**, pois a causa mais provável está no novo cliente do Ledger introduzido no deploy, não em falta de capacidade computacional.

---

## Timeline resumida

| Horário (UTC)     | Evento                                                                          | Métrica relevante                     |
| ----------------- | ------------------------------------------------------------------------------- | ------------------------------------- |
| 23/04 18:42       | Deploy v2.47.0 → v2.48.0 (novo pool Ledger, timeout 5s→2s, bump psycopg)        | —                                     |
| 24/04 13:30       | Operação normal                                                                 | p99 420ms, erro 0.2%                  |
| 24/04 14:00       | Início de degradação                                                            | p99 780ms, erro 0.8%, req_rate 1780/s |
| 24/04 14:10       | Degradação acelera                                                              | p99 2400ms, erro 4.5%                 |
| 24/04 14:15       | Pool esgota, circuit breaker perto do gatilho                                   | p99 5200ms, erro 8.2%                 |
| 24/04 14:19–14:20 | Pool exhausted (147 esperando), circuit breaker OPEN (87%), fila cresce 800/min | p99 8100ms, erro 11.7%                |

**Gap deploy → sintoma: ~19h20min.** Não é uma falha imediata pós-deploy — é uma condição latente exposta pelo aumento de tráfego (req_rate subiu de 1200/s para 2650/s, +120%, no mesmo período da degradação).

---

## Causa raiz

**Alta confiança:** o novo cliente/pool do Ledger (v2.48.0) não libera conexões corretamente sob timeout/erro.

- Evidência: `pool exhausted (max=20, active=20, waiting=147)` seguido de `connection reset by peer` — conexões presas, não erros de tráfego puro.
- 20 (max por pod) × 12 pods = 240, exatamente o valor observado em "Conexões ativas ao Ledger: 240/250" — o pool está estruturalmente sem margem, e o esgotamento bate no teto do RDS.

**Média confiança:** o timeout reduzido de 5s para 2s aumentou a taxa de queries que expiram sob carga elevada, contribuindo para o acúmulo de conexões travadas em vez de simplesmente falhar rápido e liberar.

- Evidência: `query timeout after 2000ms` imediatamente anterior ao esgotamento do pool.

**Baixa probabilidade: gargalo de capacidade computacional pura.**

- CPU 62% e memória 71% não estão saturadas, apesar do HPA no teto (12/12 pods) — isso descarta capacidade de CPU/memória como causa primária. O teto do HPA aqui é irrelevante: mais pods só multiplicam o número de conexões pedidas ao Ledger (mais pools de 20), piorando o problema em vez de resolver.

---

## Por que rollback resolveria (ou não)

1. **Resolveria**: remove o novo cliente do pool, revertendo ao comportamento testado de v2.47.0 que sustentava tráfego equivalente sem esgotar conexões.
2. **Resolveria**: restaura timeout de 5s, reduzindo a pressão de queries expirando sob carga.
3. **Parcial**: não é instantâneo — requer restart dos pods para forçar liberação das conexões já presas no RDS (240/250 não se libera sozinho apenas trocando a imagem).
4. **Risco residual**: se o bump de psycopg (não o pool) for parte da causa, o rollback resolve porque reverte ambos juntos — mas não há como isolar isso com os dados disponíveis.
5. **Não resolveria** o backlog já acumulado na fila — rollback ataca a causa da degradação, não o volume pendente.

## Por que scaling resolveria (ou não)

1. **Não ataca a causa raiz**: se o problema é conexão presa/vazamento no cliente novo, aumentar limites do RDS só adia o esgotamento, não o elimina.
2. **Risco**: aumentar o pool por pod (>20) com o cliente atual pode saturar o RDS mais rápido, já que hoje 240/250 já é quase o teto com pool menor.
3. **Poderia** dar alívio temporário (minutos) se o RDS realmente suportar mais conexões, comprando tempo para diagnóstico — mas os dados não mostram headroom real do RDS (limite é 250, já usando 240).
4. **Não resolve** a taxa de erro/circuit breaker, que é causada por timeouts e reset de conexão, não por limite de conexão simultânea per se.
5. **Mais lento a reverter**: mudança de infraestrutura (RDS, pool sizing) tende a levar mais tempo para aplicar e validar do que um rollback de deploy já testado em produção.

---

## Impacto atual e projetado

- **Fila**: 50.127 mensagens, +800/min, lag 18min crescendo. Sem intervenção, lag e volume continuam subindo enquanto erro/latência não caírem — mesmo pós-mitigação, o backlog levará minutos adicionais para drenar (a fila só some quando erro/latência voltarem a níveis normais, não instantaneamente).
- **Latência**: trajetória de 420ms→8100ms em 50min é exponencial; sem ação, a tendência é circuit breaker permanecer OPEN e taxa de erro seguir subindo além de 11.7%.
- **Erro**: 11.7% e em aceleração — cada intervalo de 15min mais que dobrou o erro anterior.

---

## Plano de ação imediato

1. Iniciar rollback para v2.47.0 via Argo CD agora.
2. Assim que o rollback completar, forçar restart/rolling restart dos pods chronos-api para liberar conexões presas no RDS.
3. Monitorar `active connections` no RDS e `err_rate`/`p99` a cada 2–3 min.
4. Acompanhar consumer lag da fila chronos-transactions para confirmar início de drenagem.

**Critério de sucesso em 10 minutos:** erro < 2% e conexões ativas caindo de 240 para bem abaixo de 250.

---

## Riscos da ação recomendada e opção de contorno

- **Risco**: rollback remove o endpoint `POST /v2/transactions/batch` — se algum cliente já depende dele em produção, haverá quebra funcional adicional (não há dado suficiente para confirmar uso real).
- **Risco**: se as conexões presas não forem liberadas por soft restart, pode ser necessário reciclar conexões no lado do RDS.

**Plano B (se erro não cair abaixo de 5% em 10 min pós-rollback):** isso indicaria que a causa não é só o cliente do pool, e sim algo mais estrutural (ex.: RDS já operando perto do limite físico independente do deploy). Nesse caso, escalar limite de conexões do RDS como medida emergencial de contorno, e aplicar rate limiting/backpressure no endpoint `/v2/transactions/batch` para proteger o Ledger enquanto a fila drena.

## Justificativa

O R-I-S-E é ideal aqui porque precisamos de uma decisão técnica baseada em evidências, não de um texto genérico. Ele amarra bem o contexto e o passo a passo da IA. O maior ganho é evitar decisões sem evidências, como escalar o RDS ou reverter o deploy logo de cara. Temos saturação clara na rota Chronos-Ledger, mas ainda não dá para cravar se o gargalo é o novo pool, o endpoint batch, o banco ou o novo driver

Em comparação, o R-T-F oferece uma simplicidade e rapidez, além de ajudar a produzir um documento bem formatado. Porém, perderia controle sobre a decomposição das evidências. Neste caso, isso aumentaria o risco de gerar um postmortem organizado, mas superficial.

Por outro lado O C-A-R-E ganharia em clareza narrativa, entretanto, como a ação ainda não foi escolhida, o framework pode pressupor uma sequência retrospectiva que não existe. Também perderia precisão para representar as lacunas de observabilidade, os cenários alternativos e os critérios objetivos necessários para decidir entre rollback e scaling.

Portanto, o R-I-S-E oferece o melhor equilíbrio entre contexto técnico, raciocínio estruturado, controle de incerteza e orientação para decisão. Ele preserva os benefícios de clareza dos demais frameworks, mas acrescenta os elementos essenciais para este caso.
