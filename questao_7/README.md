# Questao 7

## Prompt:

```
# Role
Você é um engenheiro DevOps/SRE com mais de 20 anos de experiência. Sua tarefa é redigir um runbook operacional claro, objetivo e autossuficiente, que qualquer plantonista consiga seguir do início ao fim sem precisar de ajuda externa

# Input

Contexto do incidente recorrente: o Beacon dispara em média 4 vezes por semana o alerta [CRITICAL] High memory usage on Chronos API pods (>85% for 10min) no canal de plantão. Hoje a resolução leva entre 30 e 40 minutos, com grande variação de tempo porque não existe procedimento documentado.

Ambiente?

- Chronos roda no EKS, namespace production, 6 réplicas com HPA configurado (min 4, - max 12, CPU target 70%).
- Deploy via Argo CD a partir do repositório hvt/chronos-api.
- Dependências diretas: Ledger (PostgreSQL) e Reactor (filas SQS).
- Observabilidade: métricas expostas em /metrics, logs centralizados no Beacon, dashboards em Grafana.
- Ferramentas disponíveis para o plantão: kubectl, aws cli, argocd cli.
- Canal de plantão: #oncall-chronos no Slack.
- Time sênior de escalação: @chronos-core (SLA de resposta: 15 minutos em horário comercial, 30 fora).


# Steps
 - Cabelho de indentificação com nome do alerta, severidade e sistema afetado.
 - Diagnóstico inical passo a passo, cada passo deve contar o comando específico que será executado
 - Liste as possíveis ações corretivas que podem ser tomadas
 - Relate os critérios de forma clara de como escalar para o time sênior
 - Liste critério para encerrar o incidente.

# Expectation

Espero um Runbook estruturado com seções como títulos, subtítulos e blocos de comandos bem estruturados. Escreva de forma clara e de fácil entendimento, sem textos longos e prolixos sem perder a qualidade da informação.

```

## Modelo

GPT 5.6 — claro em runbooks operacionais passo a passo.

## Output:

# Runbook — High memory usage on Chronos API pods

## 1. Identificação do incidente

| Campo                | Valor                                                                 |
| -------------------- | --------------------------------------------------------------------- |
| **Alerta**           | `[CRITICAL] High memory usage on Chronos API pods (>85% for 10min)`   |
| **Severidade**       | Critical                                                              |
| **Sistema afetado**  | Chronos API                                                           |
| **Ambiente**         | EKS — namespace `production`                                          |
| **Dependências**     | Ledger — PostgreSQL; Reactor — filas SQS                              |
| **Canal de plantão** | `#oncall-chronos`                                                     |
| **Escalação**        | `@chronos-core`                                                       |
| **SLA de resposta**  | 15 minutos em horário comercial; 30 minutos fora do horário comercial |

---

## 2. Objetivo

Restabelecer a estabilidade dos pods da Chronos API, evitando:

- `OOMKilled`;
- indisponibilidade ou redução excessiva de réplicas;
- aumento de latência ou erros HTTP;
- impacto nas integrações com Ledger e Reactor;
- reincidência imediata após a intervenção.

### Ordem de execução

1. Confirmar o alerta e o contexto;
2. Identificar os pods e o padrão de consumo;
3. Verificar deployment, HPA e nós;
4. Investigar logs, métricas e dependências;
5. Aplicar a ação corretiva de menor risco;
6. Monitorar a recuperação;
7. Escalar ou encerrar conforme os critérios definidos.

---

# 3. Diagnóstico inicial

## 3.1 Confirmar o contexto do cluster

```bash
kubectl config current-context
kubectl cluster-info
kubectl get namespace production
aws sts get-caller-identity
```

Confirme que o contexto do `kubectl` e a conta AWS correspondem ao ambiente de produção.

> Se o contexto ou a conta AWS estiverem incorretos, não execute ações de alteração.

---

## 3.2 Registrar o início no Slack

Publique no canal `#oncall-chronos`:

```text
[INCIDENTE INICIADO] [CRITICAL] High memory usage on Chronos API pods
Ambiente: production
Início: <HH:MM UTC>
Investigação iniciada. Sem ação corretiva aplicada até o momento.
```

Registre:

- horário do primeiro alerta;
- horário de cada ação;
- comandos relevantes e resultados;
- impacto observado;
- pessoas envolvidas na escalação.

---

## 3.3 Identificar deployment, pods e réplicas

```bash
kubectl -n production get deploy -o wide
kubectl -n production get deploy chronos-api -o wide
kubectl -n production describe deploy chronos-api
```

Se `chronos-api` não existir, localize o deployment:

```bash
kubectl -n production get deploy \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas
```

Liste os pods:

```bash
kubectl -n production get pods -o wide
kubectl -n production get pods -l app=chronos-api -o wide
```

Caso o label seja diferente, obtenha os labels do deployment:

```bash
kubectl -n production get deploy chronos-api \
  -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
```

Confirme:

- status dos pods;
- quantidade de réplicas;
- número de reinicializações;
- nó utilizado;
- estado `Ready`;
- pods pendentes ou terminando.

---

## 3.4 Verificar o consumo de memória

```bash
kubectl -n production top pod --containers
```

Verifique os recursos configurados:

```bash
kubectl -n production get deploy chronos-api \
  -o custom-columns=NAME:.metadata.name,CPU_REQUEST:.spec.template.spec.containers[*].resources.requests.cpu,MEM_REQUEST:.spec.template.spec.containers[*].resources.requests.memory,CPU_LIMIT:.spec.template.spec.containers[*].resources.limits.cpu,MEM_LIMIT:.spec.template.spec.containers[*].resources.limits.memory
```

Verifique reinicializações e encerramentos por memória:

```bash
kubectl -n production get pods -l app=chronos-api \
  -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{range .status.containerStatuses[*]}{.name}{" restart="}{.restartCount}{" reason="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}{end}'
```

### Interpretação

- **Todos os pods com consumo elevado:** possível aumento de carga, vazamento comum, mudança recente ou limite subdimensionado.
- **Apenas alguns pods elevados:** possível vazamento localizado, requisição específica ou distribuição desigual.
- **Consumo próximo do limite com reinicializações:** risco imediato de `OOMKilled`.
- **`kubectl top` sem dados:** utilizar Grafana, Beacon e logs; não presumir que o consumo está normal.

---

## 3.5 Verificar o estado do deployment

```bash
kubectl -n production rollout status deployment/chronos-api --timeout=60s
kubectl -n production get deploy chronos-api
kubectl -n production describe deploy chronos-api
```

Liste pods fora de `Running`:

```bash
kubectl -n production get pods -l app=chronos-api \
  --field-selector=status.phase!=Running -o wide
```

Consulte eventos recentes:

```bash
kubectl -n production get events \
  --sort-by=.lastTimestamp | tail -n 50
```

Procure por:

- `OOMKilled`;
- `Evicted`;
- falhas de readiness ou liveness;
- `FailedScheduling`;
- `FailedMount`;
- `Back-off restarting failed container`;
- falta de recursos;
- problemas de imagem.

---

## 3.6 Verificar o HPA

```bash
kubectl -n production get hpa
kubectl -n production describe hpa chronos-api
```

Consulte os valores atuais:

```bash
kubectl -n production get hpa \
  -o custom-columns=NAME:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,CPU:.status.currentMetrics[*].resource.current.averageUtilization
```

Consulte as condições do HPA:

```bash
kubectl -n production describe hpa chronos-api | sed -n '/Conditions:/,/Events:/p'
```

O HPA atual utiliza CPU com alvo de 70%. Portanto, ele pode não escalar quando o problema for exclusivamente memória.

---

## 3.7 Verificar os nós do EKS

Identifique os nós utilizados pela Chronos:

```bash
kubectl -n production get pods -l app=chronos-api \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```

Verifique capacidade e condições dos nós:

```bash
kubectl get nodes
kubectl top nodes
kubectl describe nodes
```

Consulte especificamente a pressão de memória:

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY_PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status
```

Procure por:

- `MemoryPressure`;
- falta de memória disponível;
- concentração dos pods Chronos em um único nó;
- evictions;
- falhas de autoscaling do grupo de nós.

---

## 3.8 Analisar logs da aplicação

Liste os pods:

```bash
kubectl -n production get pods -l app=chronos-api -o name
```

Consulte logs recentes de um pod com consumo alto:

```bash
kubectl -n production logs <pod> \
  --since=30m \
  --timestamps \
  --all-containers=true
```

Para acompanhar novos eventos:

```bash
kubectl -n production logs -f <pod> \
  --since=10m \
  --timestamps \
  --all-containers=true
```

Se o pod tiver reiniciado:

```bash
kubectl -n production logs <pod> \
  --previous \
  --timestamps \
  --all-containers=true
```

Pesquise padrões relevantes:

```bash
kubectl -n production logs <pod> \
  --since=30m \
  --all-containers=true | \
  grep -Ei 'oom|out of memory|heap|memory|timeout|connection|pool|queue|ledger|reactor|error|exception'
```

No Beacon, verifique:

- aumento de erros HTTP 5xx;
- aumento de latência;
- requisições específicas;
- falhas de conexão com Ledger;
- lentidão ou backlog no Reactor;
- exceções repetitivas;
- payloads grandes;
- erros de serialização;
- processamento em lote.

---

## 3.9 Verificar métricas da aplicação

Descubra a porta configurada:

```bash
kubectl -n production get deploy chronos-api \
  -o jsonpath='{range .spec.template.spec.containers[*].ports[*]}{.name}{" "}{.containerPort}{"\n"}{end}'
```

Faça o encaminhamento da porta:

```bash
kubectl -n production port-forward deployment/chronos-api 18080:8080
```

Em outro terminal:

```bash
curl -fsS http://127.0.0.1:18080/metrics | head -n 40
```

No Grafana, compare no mesmo intervalo:

- memória por pod;
- memória em relação ao request e ao limit;
- CPU;
- requisições;
- erros;
- latência;
- reinicializações;
- número de réplicas;
- throughput.

Analise pelo menos:

- últimos 15 minutos;
- última hora;
- mesmo período do dia anterior, quando disponível.

Finalize o `port-forward` com `Ctrl+C`.

---

## 3.10 Verificar Ledger e Reactor

### Ledger — PostgreSQL

No Beacon e nos dashboards, verifique:

- falhas de conexão;
- pool de conexões esgotado;
- aumento de latência;
- timeouts;
- consultas lentas;
- transações pendentes.

> Não reinicie nem altere o PostgreSQL como parte deste runbook.

### Reactor — SQS

Identifique as filas configuradas:

```bash
kubectl -n production get deploy chronos-api \
  -o yaml | grep -Ei 'sqs|queue|reactor'
```

Consulte variáveis de ambiente sem expor segredos:

```bash
kubectl -n production exec deploy/chronos-api -- \
  sh -c 'env | grep -Ei "SQS|QUEUE|REACTOR" | sed -E "s/(KEY|SECRET|TOKEN|PASSWORD)=.*/\1=<redacted>/"'
```

Para cada fila, consulte mensagens visíveis:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value=<nome-da-fila> \
  --statistics Maximum \
  --period 300 \
  --start-time "$(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
```

Verifique:

- mensagens visíveis;
- mensagens em processamento;
- idade da mensagem mais antiga;
- taxa de consumo;
- aumento de retries.

Não descarte mensagens nem faça purge de filas sem autorização.

---

## 3.11 Verificar alterações recentes no Argo CD

```bash
argocd app list
argocd app get <app-chronos>
argocd app history <app-chronos>
argocd app diff <app-chronos>
```

No repositório `hvt/chronos-api`, procure mudanças recentes em:

- requests e limits de memória;
- HPA;
- réplicas;
- processamento em lote;
- cache;
- consumidores do Reactor;
- conexões com Ledger;
- probes;
- dependências;
- imagem da aplicação.

Uma alteração recente correlacionada ao início do alerta aumenta a probabilidade de regressão.

---

# 4. Ações corretivas

Aplique a ação de menor risco compatível com a evidência encontrada.

## 4.1 Aumentar temporariamente o número de réplicas

Use quando:

- houver aumento de carga;
- os pods estiverem individualmente saudáveis;
- o consumo puder ser distribuído;
- houver recursos disponíveis no cluster;
- não houver evidência de vazamento comum.

Confirme o estado atual:

```bash
kubectl -n production get hpa
kubectl -n production describe hpa <nome-do-hpa>
```

O máximo atual é 12 réplicas. Garanta que o HPA não ultrapasse esse valor:

```bash
kubectl -n production patch hpa <nome-do-hpa> \
  --type=merge \
  -p '{"spec":{"maxReplicas":12}}'
```

Se necessário, aumente temporariamente o mínimo:

```bash
kubectl -n production patch hpa <nome-do-hpa> \
  --type=merge \
  -p '{"spec":{"minReplicas":8}}'
```

Após a estabilização, reverta:

```bash
kubectl -n production patch hpa <nome-do-hpa> \
  --type=merge \
  -p '{"spec":{"minReplicas":4}}'
```

A alteração definitiva deve ser feita no repositório `hvt/chronos-api` e sincronizada pelo Argo CD.

---

## 4.2 Reiniciar pods com suspeita de vazamento localizado

Use somente quando:

- um ou poucos pods apresentarem crescimento anormal;
- o restante da frota estiver saudável;
- existirem réplicas prontas suficientes;
- não houver deploy em andamento;
- a readiness probe estiver funcionando.

Valide antes:

```bash
kubectl -n production get pods -l app=chronos-api -o wide
kubectl -n production get deploy chronos-api
kubectl -n production get pdb
```

Reinicie um pod por vez:

```bash
kubectl -n production delete pod <pod-com-alto-consumo>
kubectl -n production rollout status deployment/chronos-api --timeout=120s
```

Depois valide:

```bash
kubectl -n production get pods -l app=chronos-api -o wide
kubectl -n production top pod --containers
```

> Nunca reinicie todos os pods simultaneamente.

---

## 4.3 Fazer rollback de alteração recente

Use quando:

- o problema começou após uma sincronização ou deploy;
- os logs indicarem regressão;
- existir uma versão conhecida como saudável.

Consulte o histórico:

```bash
argocd app history <app-chronos>
```

Comunique a ação:

```text
Identificada possível regressão após alteração recente.
Propondo rollback da aplicação <app-chronos> para o histórico ID <ID>.
```

Execute o rollback aprovado:

```bash
argocd app rollback <app-chronos> <ID>
```

Acompanhe:

```bash
argocd app get <app-chronos>
kubectl -n production rollout status deployment/chronos-api --timeout=180s
```

Valide:

```bash
kubectl -n production get pods -l app=chronos-api -o wide
kubectl -n production top pod --containers
```

O rollback deve ser posteriormente corrigido e formalizado no repositório.

---

## 4.4 Aumentar request/limit de memória

Use quando:

- não houver evidência de vazamento;
- o consumo estiver estável, mas próximo do limite;
- a carga normal tiver aumentado;
- o valor atual estiver subdimensionado;
- houver memória disponível nos nós.

A alteração permanente deve ser feita no repositório `hvt/chronos-api`.

Antes, valide a capacidade:

```bash
kubectl top nodes
kubectl describe nodes
```

Fluxo recomendado:

1. Alterar requests e limits no repositório;
2. Revisar a alteração;
3. Fazer merge conforme o processo de mudança;
4. Sincronizar pelo Argo CD;
5. Acompanhar o rollout;
6. Monitorar memória, erros e latência.

> Não altere permanentemente o deployment apenas com `kubectl edit` ou `kubectl patch`.

---

## 4.5 Reduzir temporariamente carga ou consumidores

Considere esta ação quando houver:

- backlog crescente no Reactor;
- processamento excessivo por mensagem;
- payloads anormalmente grandes;
- origem específica causando sobrecarga;
- saturação do Ledger.

Medidas possíveis, com aprovação do `@chronos-core`:

- reduzir temporariamente consumidores;
- reduzir concorrência;
- desabilitar funcionalidade recém-introduzida;
- limitar tráfego de uma origem;
- interromper rotina em lote.

Não descarte mensagens, faça purge de filas ou altere dados do Ledger sem autorização explícita.

---

## 4.6 Corrigir problema de nó

Se o problema estiver concentrado em um nó com `MemoryPressure`, evictions ou falha de infraestrutura:

1. Confirme que há réplicas suficientes;
2. Verifique o PodDisruptionBudget;
3. Escale para o time responsável pelo EKS;
4. Faça drain somente com autorização.

Não execute `kubectl drain` durante o incidente sem avaliar:

- réplicas disponíveis;
- capacidade dos demais nós;
- impacto em outros workloads;
- PDB;
- autorização do responsável pelo cluster.

---

# 5. Critérios de escalação

Escalone para `@chronos-core` imediatamente quando ocorrer qualquer uma das condições abaixo:

- pod em `OOMKilled`;
- `CrashLoopBackOff` ou reinicializações contínuas;
- menos de quatro réplicas `Ready`;
- falha de readiness ou liveness em múltiplos pods;
- memória acima de 95% do limite;
- crescimento contínuo de memória;
- aumento de erros HTTP 5xx;
- latência acima do padrão;
- impacto confirmado para usuários;
- backlog do Reactor crescendo continuamente;
- Ledger com timeout, saturação ou falhas;
- necessidade de ultrapassar 12 réplicas;
- necessidade de alterar código, banco, filas ou configuração crítica;
- rollback sem versão conhecida como saudável;
- suspeita de vazamento;
- ausência de melhora após uma ação corretiva;
- causa não identificada após 15 minutos em horário comercial;
- causa não identificada após 30 minutos fora do horário comercial.

Mensagem de escalação:

```text
[ESCALAÇÃO] [CRITICAL] High memory usage on Chronos API pods

Início: <HH:MM UTC>
Impacto: <descrever impacto>

Estado atual:
- Réplicas Ready: <X>/<Y>
- Memória: <valor ou percentual>
- OOMKilled/restarts: <informar>
- Erros/latência: <informar>
- Ledger: <normal/degradado>
- Reactor/SQS: <normal/degradado>

Ações executadas:
1. <ação> — <resultado>
2. <ação> — <resultado>

Hipótese atual: <causa provável>
Ação necessária: <decisão ou apoio solicitado>
```

Se não houver resposta dentro do SLA aplicável, registre no Slack e utilize o próximo canal de escalação definido pela organização.

---

# 6. Critérios para encerrar o incidente

Encerre somente quando todos os critérios forem atendidos:

- alerta resolvido no Beacon;
- memória abaixo de 85%, preferencialmente abaixo de 80%, por pelo menos 15 minutos;
- ausência de crescimento contínuo de memória;
- nenhum `OOMKilled` recente;
- nenhuma reinicialização anormal;
- todos os pods esperados em estado `Ready`;
- rollout concluído e estável;
- HPA sem erros;
- réplicas dentro do esperado;
- erros HTTP e latência normalizados;
- Ledger sem timeouts ou saturação;
- Reactor sem crescimento anormal de backlog;
- nenhuma alteração emergencial pendente;
- alterações temporárias revertidas ou formalizadas no repositório;
- comunicação de encerramento publicada no Slack.

Mensagem de encerramento:

```text
[RESOLVIDO] [CRITICAL] High memory usage on Chronos API pods

Resolvido às: <HH:MM UTC>
Duração: <duração>
Causa provável: <causa>
Ação aplicada: <ação>

Estado final:
- Réplicas Ready: <X>/<Y>
- Memória: <percentual>
- OOMKilled/restarts: <informar>
- Erros/latência: normalizados
- Ledger: normal
- Reactor/SQS: normal

Acompanhamento pós-incidente: <ticket ou referência>
```

---

# 7. Acompanhamento pós-incidente

Como o alerta ocorre em média quatro vezes por semana, criar uma tarefa preventiva após cada incidente para:

- confirmar se o alerta mede memória em relação ao request ou ao limit;
- avaliar inclusão de memória como métrica do HPA;
- investigar possíveis vazamentos;
- revisar requests e limits;
- analisar payloads e processamento do Reactor;
- revisar pool de conexões e consultas ao Ledger;
- correlacionar incidentes com deploys;
- criar dashboard por pod, versão e nó;
- ajustar o alerta para antecipar o risco de `OOMKilled`;
- registrar a causa raiz e a correção definitiva.

## Justificativa

O prompt segue a estrutura Role / Input / Steps / Expectation: na Role foi definida a persona de engenheiro DevOps/SRE responsável por um runbook autossuficiente, já no Input foram fornecidos o contexto do alerta recorrente, o ambiente.Nos Steps foram listadas as seções obrigatórias (identificação, diagnóstico com comandos, ações corretivas, critérios de escalação e encerramento) e na Expectation foi exigida entrega estruturada, objetiva e com blocos de comandos.
