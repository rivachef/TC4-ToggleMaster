# Problemas Encontrados e Solucoes - ToggleMaster Fase 4

Registro detalhado de todos os problemas encontrados durante a implementacao da Fase 4, suas causas raiz e as solucoes aplicadas. Este documento serve como base para o RELATORIO-ENTREGA-FASE4.

---

## 1. New Relic - Go Services Sem Dados no APM

**Sintoma:** auth-service e evaluation-service apareciam no New Relic APM (listados com dot verde), mas mostravam `–` para throughput, response time e error rate. Os 3 servicos Python (flag, targeting, analytics) mostravam dados normalmente (~6-7 rpm).

**Investigacao:**
- OTel Collector debug logs confirmaram que traces e metrics de TODOS os 5 servicos estavam sendo recebidos e exportados
- Collector metrics mostraram 5.799 spans enviados ao New Relic com ZERO drops
- Conclusao: os dados CHEGAVAM ao New Relic, mas nao eram classificados como "web transactions"

**Causa Raiz:** Os servicos Go usavam um middleware OTel customizado (`otel_middleware.go`) que criava metricas com nomes nao-padrao:
- Custom: `http_server_request_duration_seconds` (nao reconhecido pelo NR)
- Standard OTel: `http.server.request.duration` (reconhecido pelo NR)

O New Relic deriva throughput e response time a partir de metricas com nomes padrao do OTel HTTP semantic conventions. Metricas com nomes customizados sao armazenadas mas nao aparecem na view de APM.

Os servicos Python usam `opentelemetry-instrument` (auto-instrumentacao) que emite `http.server.duration` — nome padrao reconhecido pelo New Relic.

**Tentativa 1 (nao resolveu):** Adicionamos `resource.WithTelemetrySDK()`, `resource.WithFromEnv()` e `resource.WithHost()` ao `resource.New()` do Go. Isso adicionou atributos como `telemetry.sdk.language=go` e `service.namespace=togglemaster`, mas NAO resolveu o throughput `–` porque o problema era o nome da metrica, nao os atributos do resource.

**Solucao Final:** Substituimos o middleware customizado pelo handler oficial `otelhttp.NewHandler()` do pacote `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`:

```go
// ANTES (custom middleware - NR nao reconhecia)
handler := otelMiddleware(mux)

// DEPOIS (oficial - NR reconhece)
handler := otelhttp.NewHandler(mux, "auth-service")
```

O `otelhttp.NewHandler()` cria automaticamente:
- Metrica `http.server.request.duration` (nome padrao OTel)
- Spans com `span.kind=SERVER` e atributos semconv corretos
- Propagacao automatica de contexto W3C

**Arquivos alterados:**
- `microservices/auth-service/main.go` — import otelhttp, remover initOtelMetrics, usar otelhttp.NewHandler
- `microservices/evaluation-service/main.go` — idem
- `microservices/auth-service/telemetry.go` — adicionado WithFromEnv, WithTelemetrySDK, WithHost
- `microservices/evaluation-service/telemetry.go` — idem
- `microservices/auth-service/go.mod` — adicionado otelhttp v0.53.0
- `microservices/evaluation-service/go.mod` — idem

**Licao aprendida:** Em Go, sempre usar `otelhttp` para instrumentacao HTTP ao inves de middleware manual. O equivalente Python (`opentelemetry-instrument`) faz isso automaticamente; em Go e preciso ser explicito.

---

## 2. New Relic - Transport gRPC Falhando (Traces Nao Chegavam)

**Sintoma:** OTel Collector logava erro "server closed the stream without sending trailers" ao exportar traces para New Relic via gRPC.

**Causa Raiz:** O exporter `otlp/newrelic` usava gRPC (porta 4317) para enviar traces ao New Relic. O endpoint `otlp.nr-data.net:4317` apresentava instabilidade na conexao gRPC.

**Solucao:** Trocamos o exporter de gRPC para HTTP:

```yaml
# ANTES
otlp/newrelic:
  endpoint: "otlp.nr-data.net:4317"

# DEPOIS
otlphttp/newrelic:
  endpoint: "https://otlp.nr-data.net"
```

**Arquivo alterado:** `gitops/monitoring/otel-collector/values.yaml`

---

## 3. New Relic - 403 Forbidden (API Key Errada)

**Sintoma:** Apos trocar para HTTP, OTel Collector recebia 403 Forbidden do New Relic.

**Causa Raiz:** O botao "Copy key" no New Relic copiava o Key ID (`338B49...`) em vez do valor real da license key (`7cfd918b...`). O Key ID e um identificador, nao a credencial.

**Solucao:** Gerar uma nova INGEST LICENSE key no New Relic, copiar o VALOR real (nao o ID), e aplicar no Kubernetes secret `newrelic-license-key`.

**Licao aprendida:** No New Relic, ao copiar API keys, verificar se esta copiando o VALOR e nao o ID. O valor comecar com caracteres como `7cfd...` (INGEST) ou `NRAK-...` (USER).

---

## 4. Alertmanager Secret Sobrescrito pelo Helm

**Sintoma:** Alertas configurados (PagerDuty + Discord) paravam de funcionar apos reinstalar o monitoring stack. O secret do Alertmanager voltava para o default do Helm.

**Causa Raiz:** O `setup-full.sh` aplicava o secret do Alertmanager no step 9 (ANTES do Helm install no step 10). O `helm upgrade --install` do kube-prometheus-stack sobrescrevia o secret com o valor default.

**Solucao:** Movemos a aplicacao do secret para DEPOIS do Helm install, dentro do `install-monitoring.sh`:

```bash
# Post-install: Apply Alertmanager custom config (AFTER Helm)
kubectl apply --server-side --force-conflicts -f "$AM_SECRET_FILE"
```

O `--server-side --force-conflicts` garante que nosso secret sobrescreve o do Helm.

**Arquivos alterados:**
- `scripts/setup-full.sh` — removido apply do alertmanager secret do step 9
- `scripts/install-monitoring.sh` — adicionado apply post-Helm no final

---

## 5. destroy-all.sh Falhando no macOS (grep -P)

**Sintoma:** O script `destroy-all.sh` abortava no macOS com erro de `grep -P` (Perl regex).

**Causa Raiz:** O macOS usa BSD grep que nao suporta a flag `-P` (Perl regex). O script usava `grep -oP 'ID:\s+\K[\w-]+'` para extrair o Terraform lock ID.

**Solucao:** Substituimos por uma cadeia de comandos compativeis com BSD e GNU:

```bash
# ANTES (Linux-only)
LOCK_ID=$(echo "$PLAN_OUTPUT" | grep -oP 'ID:\s+\K[\w-]+')

# DEPOIS (macOS-compatible)
LOCK_ID=$(echo "$PLAN_OUTPUT" | grep 'ID:' | head -1 | sed 's/.*ID:[[:space:]]*//' | tr -d '[:space:]')
```

Tambem adicionamos `-lock=false` no `terraform plan` e `-lock-timeout=60s` no `terraform destroy`.

**Arquivo alterado:** `scripts/destroy-all.sh`

---

## 6. Terraform State Lock Preso (2 ocorrencias)

**Sintoma:** `terraform destroy` falhava com "Error acquiring the state lock" com lock IDs diferentes.

**Causa 1:** O script antigo (com `grep -P`) abortava no meio da execucao, deixando o lock ativo no DynamoDB.

**Causa 2:** Um background task rodou o script antigo (antes do fix ser aplicado) e tambem deixou lock preso.

**Solucao:** `terraform force-unlock -force <LOCK_ID>` para cada lock, seguido de destroy com o script corrigido.

**Lock IDs desbloqueados:**
- `1621efe1-39e4-5536-102e-22f294c63766`
- `8a24dcc7-32a0-d1da-ffaf-2595bb9b97ad`

---

## 7. ElastiCache API Error no Terraform Destroy

**Sintoma:** `terraform destroy` falhava com "reading ElastiCache Subnet Group: UnknownError" durante o refresh do state.

**Causa Raiz:** O recurso ElastiCache ja havia sido parcialmente deletado manualmente, mas o Terraform state ainda referenciava-o. O refresh falhava ao tentar ler um recurso que nao existia mais.

**Solucao:** `terraform destroy -auto-approve -refresh=false` para pular o state refresh e destruir baseado no state salvo.

---

## 8. GitHub Push Protection Bloqueando Commit

**Sintoma:** `git push` falhava com "Push Protection" por detectar um token (GitHub PAT) no arquivo `alertmanager-secret.yaml`.

**Causa Raiz:** O arquivo `alertmanager-secret.yaml` continha credenciais reais (PagerDuty key, Discord webhook, GitHub PAT) e foi incluido acidentalmente no commit.

**Solucao:**
1. `git reset HEAD~1` para desfazer o commit
2. Adicionar `alertmanager-secret.yaml` ao `.gitignore`
3. Manter apenas o template (`alertmanager-config.yaml`) com placeholders no repositorio
4. Commitar apenas scripts e templates, nunca secrets

**Licao aprendida:** Secrets com credenciais reais NUNCA devem ser commitados. Usar `.gitignore` e templates com placeholders.

---

## 9. ArgoCD Sincronizou Placeholders (Pods com InvalidImageName)

**Sintoma:** Apos commit de HPAs e PDBs, ArgoCD sincronizou os deployments e criou pods com imagem `<AWS_ACCOUNT_ID>.dkr.ecr...` (placeholder literal), resultando em `InvalidImageName`.

**Causa Raiz:** Os manifestos no git ainda tinham `<AWS_ACCOUNT_ID>` como placeholder. O commit dos HPAs/PDBs trigou um sync do ArgoCD que tambem aplicou os deployments com placeholders.

**Solucao:**
1. Substituir placeholders com valores reais nos deployment.yaml
2. Commit e push dos manifestos atualizados
3. ArgoCD auto-sincronizou com as imagens corretas
4. Scale down manual do ReplicaSet orfao

---

## 10. OpsGenie Descontinuado - Migracao para PagerDuty

**Sintoma:** A documentacao original do projeto referenciava OpsGenie para incident management.

**Causa Raiz:** A Atlassian migrou o OpsGenie para o Jira Service Management, descontinuando o produto standalone.

**Solucao:** Migramos para PagerDuty que oferece:
- Free tier adequado para o projeto
- Integracao nativa no Alertmanager via `pagerduty_configs`
- Events API v2 (simples e direto)

**Arquivos atualizados:**
- `docs/RESUMO-EXECUTIVO.md` — todas referencias OpsGenie → PagerDuty
- `docs/PIPELINE-EXPLAINED.md` — diagrama e exporters atualizados
- `gitops/monitoring/alerting/alertmanager-config.yaml` — template com PagerDuty
- `gitops/monitoring/alerting/alertmanager-secret.yaml` — config real com PagerDuty key

---

## 11. Discord Webhook - Formato Slack Required

**Sintoma:** Alertmanager enviava alertas ao Discord mas recebia "Cannot send an empty message".

**Causa Raiz:** Discord nao aceita o formato JSON nativo do webhook do Alertmanager. Porem, Discord aceita o formato Slack-compatible quando o URL termina com `/slack`.

**Solucao:** No Alertmanager, usar `slack_configs` (nao `webhook_configs`) com o sufixo `/slack` na URL:

```yaml
slack_configs:
  - api_url: 'https://discord.com/api/webhooks/<ID>/<TOKEN>/slack'
    channel: '#alerts'
    send_resolved: true
```

---

## 12. Cluster Rodando Overnight (~$5.20 Gastos)

**Sintoma:** Esquecemos de destruir o cluster antes de encerrar a sessao. Recursos ficaram rodando por ~12 horas.

**Causa Raiz:** O `terraform destroy` foi iniciado em background mas falhou (bug do `grep -P`), e nao verificamos o resultado.

**Impacto:** ~$5.20 de creditos AWS Academy gastos desnecessariamente (de $50 total).

**Solucao preventiva:**
1. Sempre verificar o resultado de operacoes em background
2. Criar alarme no AWS para budget alerts
3. Destruir sempre ao final de cada sessao de trabalho

---

## 13. Metricas Go vs Python - Nomes Diferentes

**Contexto:** Os servicos Go e Python emitem metricas HTTP com nomes diferentes, o que afeta tanto o Grafana dashboard quanto o New Relic.

| Aspecto | Go (auth, evaluation) | Python (flag, targeting, analytics) |
|---------|----------------------|-------------------------------------|
| Instrumentacao | `otelhttp.NewHandler()` | `opentelemetry-instrument` |
| Metrica HTTP | `http.server.request.duration` | `http.server.duration` |
| Unidade | Seconds | Milliseconds |
| No Prometheus | `http_server_request_duration_seconds` | `http_server_duration_milliseconds` |
| Status code label | `http.response.status_code` | `http_status_code` |

**Impacto:** O dashboard Grafana precisa de queries separadas para Go e Python, combinadas com `or` ou UNION.

---

## 14. Loki Datasource UID Dinamico

**Sintoma:** Dashboard Grafana nao mostrava logs (panels Loki em erro).

**Causa Raiz:** O Grafana atribui um UID aleatorio ao datasource Loki em cada instalacao. O dashboard JSON referenciava um UID fixo que nao existia na nova instalacao.

**Solucao:** O `install-monitoring.sh` resolve o UID dinamicamente via API do Grafana antes de carregar o dashboard:

```bash
LOKI_UID=$(kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
  curl -sf http://localhost:3000/api/datasources -u admin:togglemaster2024 | \
  python3 -c "import sys,json; ds=json.load(sys.stdin); print(next((d['uid'] for d in ds if d['type']=='loki'),''))")
sed "s|<LOKI_DS_UID>|$LOKI_UID|g" dashboard.json > dashboard-resolved.json
```

---

## 15. Silenciamento de Alertas Ruidosos (Watchdog + KubeControllerManagerDown)

**Sintoma:** Discord recebia alertas constantes de `Watchdog` e `KubeControllerManagerDown`.

**Causa Raiz:**
- `Watchdog`: alerta de heartbeat do Prometheus, sempre firing, nao acionavel
- `KubeControllerManagerDown`: esperado em EKS gerenciado (nao temos acesso ao control plane)

**Solucao:** Adicionamos rotas de silenciamento no Alertmanager:

```yaml
routes:
  - match:
      alertname: Watchdog
    receiver: 'null'
  - match:
      alertname: KubeControllerManagerDown
    receiver: 'null'
```

---

## Resumo de Impacto

| # | Problema | Severidade | Tempo p/ Resolver | Categoria |
|---|---------|------------|-------------------|-----------|
| 1 | Go services sem APM no NR | Alta | ~2h (3 tentativas) | Instrumentacao |
| 2 | gRPC transport falhando | Alta | 30min | Configuracao |
| 3 | API Key ID vs Value | Media | 20min | Credenciais |
| 4 | Alertmanager sobrescrito | Alta | 30min | Orquestracao |
| 5 | grep -P no macOS | Media | 15min | Compatibilidade |
| 6 | Terraform locks presos | Media | 10min cada | Infraestrutura |
| 7 | ElastiCache destroy error | Baixa | 5min | Infraestrutura |
| 8 | Push Protection secrets | Media | 15min | Seguranca |
| 9 | ArgoCD sync placeholders | Alta | 20min | GitOps |
| 10 | OpsGenie descontinuado | Media | 1h | Vendor |
| 11 | Discord webhook format | Media | 15min | Integracao |
| 12 | Cluster overnight | Baixa | N/A (preventivo) | Operacional |
| 13 | Metricas Go vs Python | Baixa | N/A (by design) | Instrumentacao |
| 14 | Loki UID dinamico | Media | 30min | Dashboard |
| 15 | Alertas ruidosos | Baixa | 10min | Alerting |
