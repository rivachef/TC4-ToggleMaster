# Arquitetura de Observabilidade - ToggleMaster Fase 4

Este documento explica a arquitetura do pipeline de telemetria implementado no ToggleMaster, como os dados fluem dos microsservicos ate os backends de observabilidade, e como os alertas e automacoes funcionam.

---

## Visao Geral

O ToggleMaster utiliza o **OpenTelemetry** como padrao de instrumentacao e o **OTel Collector** como hub central de telemetria. Os tres pilares da observabilidade sao cobertos:

| Pilar | Coleta | Backend | Visualizacao |
|-------|--------|---------|-------------|
| **Metricas** | OTel SDK -> OTel Collector -> Prometheus Remote Write | Prometheus | Grafana |
| **Logs** | stdout/stderr -> Promtail -> Loki | Loki | Grafana |
| **Traces** | OTel SDK -> OTel Collector -> OTLP | New Relic | New Relic APM |

---

## 1. Instrumentacao dos Microsservicos

### Servicos Go (auth-service, evaluation-service)

Instrumentacao **manual** via OTel SDK:

```
main.go
  └── initTelemetry()          # telemetry.go
       ├── TracerProvider       # Exporta traces via OTLP gRPC
       ├── MeterProvider        # Exporta metricas via OTLP gRPC (intervalo: 15s)
       └── TextMapPropagator    # W3C TraceContext + Baggage

  └── otelMiddleware()          # otel_middleware.go
       ├── Extrai contexto do request (propagacao)
       ├── Cria span por requisicao HTTP
       ├── Registra metricas:
       │    ├── http_server_request_total (counter)
       │    └── http_server_request_duration_seconds (histogram)
       └── Propaga contexto para chamadas downstream
```

**Labels das metricas Go:**
- `service_name` (ex: "auth-service")
- `http_method` (GET, POST, etc.)
- `http_route` (URL path)
- `http_response_status_code` (200, 404, 500, etc.)

**Fluxo de uma requisicao no evaluation-service:**
```
Cliente -> evaluation-service (span criado)
            ├── GET flag-service/flags/{name}     (contexto propagado via headers)
            ├── GET targeting-service/rules/{id}  (contexto propagado via headers)
            ├── Redis GET/SET                      (operacao no span)
            └── SQS SendMessage                    (evento assincrono)
```

### Servicos Python (flag-service, targeting-service, analytics-service)

Instrumentacao **automatica** via `opentelemetry-instrument`:

```
Dockerfile CMD:
  opentelemetry-instrument gunicorn --bind 0.0.0.0:8002 app:app

Instrumentacoes automaticas carregadas:
  ├── flask          # Spans para cada rota Flask
  ├── requests       # Spans para chamadas HTTP externas (auth-service)
  ├── psycopg2       # Spans para queries PostgreSQL
  └── botocore       # Spans para chamadas AWS (SQS, DynamoDB)
```

**Labels das metricas Python:**
- `service_name` (ex: "flag-service")
- `http_method`, `http_scheme`, `http_status_code`
- `telemetry_sdk_language: python`

**Metricas emitidas automaticamente:**
- `http_server_duration_milliseconds` (histogram, em ms — diferente do Go que e em segundos)
- `http_server_active_requests` (gauge)

**Configuracao via variaveis de ambiente** (ConfigMap do K8s):
```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector-opentelemetry-collector.monitoring:4317"
OTEL_SERVICE_NAME: "flag-service"
OTEL_RESOURCE_ATTRIBUTES: "service.namespace=togglemaster,deployment.environment=production"
OTEL_TRACES_EXPORTER: "otlp"
OTEL_METRICS_EXPORTER: "otlp"
```

### Diferenca de Metricas Go vs Python

| Aspecto | Go (auth, evaluation) | Python (flag, targeting, analytics) |
|---------|----------------------|-------------------------------------|
| Instrumentacao | Manual (OTel SDK) | Automatica (opentelemetry-instrument) |
| Metrica HTTP | `http_server_request_duration_seconds` | `http_server_duration_milliseconds` |
| Unidade | Segundos | Milissegundos |
| Status code label | `http_response_status_code` | `http_status_code` |
| Counter | `http_server_request_total` | (nao emite counter separado) |

> **Nota importante**: As metricas chegam ao Prometheus via OTel Collector Remote Write e **nao possuem label `namespace`**. O dashboard Grafana filtra por `service_name` em vez de `namespace`.

---

## 2. OpenTelemetry Collector

O OTel Collector e o **hub central** que recebe, processa e roteia toda a telemetria:

```yaml
# Pipeline Configuration
service:
  pipelines:
    traces:
      receivers: [otlp]                           # gRPC :4317 + HTTP :4318
      processors: [memory_limiter, resource, batch]
      exporters: [otlphttp/newrelic, debug]         # -> New Relic (HTTP)

    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite, debug]    # -> Prometheus

    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlphttp/loki, debug]            # -> Loki (via OTLP/HTTP)
```

### Processadores

| Processador | Funcao |
|------------|--------|
| `memory_limiter` | Previne OOM (limite 400 MiB, spike 100 MiB) |
| `resource` | Adiciona atributos globais: `cluster.name=togglemaster-cluster`, `environment=production` |
| `batch` | Agrupa dados em lotes de 1024 (max 2048) com timeout de 5s |

### Exportadores

| Exporter | Destino | Protocolo |
|----------|---------|-----------|
| `prometheusremotewrite` | Prometheus `:9090/api/v1/write` | HTTP remote write |
| `otlphttp/loki` | Loki `:3100/otlp` | HTTP OTLP |
| `otlphttp/newrelic` | `https://otlp.nr-data.net` | HTTP (TLS) |

> **Nota**: Versoes anteriores do chart usavam um exporter `loki` nativo, que foi removido. Agora usamos `otlphttp/loki` com o endpoint OTLP do Loki.

### Autenticacao New Relic

A license key do New Relic e injetada via variavel de ambiente a partir de um Kubernetes Secret:

```yaml
extraEnvs:
  - name: NEW_RELIC_LICENSE_KEY
    valueFrom:
      secretKeyRef:
        name: newrelic-license-key
        key: license-key
        optional: true  # Collector funciona mesmo sem a chave (traces nao sao enviados)
```

---

## 3. Prometheus + Grafana

### Prometheus (kube-prometheus-stack)

Inclui automaticamente:
- **Prometheus Server** - Armazenamento de metricas (7 dias retencao, 5 GB)
- **Alertmanager** - Roteamento de alertas
- **node-exporter** (DaemonSet) - Metricas de host (CPU, memoria, disco, rede)
- **kube-state-metrics** - Metricas do Kubernetes (pods, deployments, nodes)

**Configuracao especial:**
- `enableRemoteWriteReceiver: true` — permite que o OTel Collector envie metricas via remote write
- `serviceMonitorSelectorNilUsesHelmValues: false` — descobre todos ServiceMonitors automaticamente
- `storageSpec: {}` — usa emptyDir (AWS Academy nao suporta EBS via OIDC)

**Scrape adicional:**
- OTel Collector metrics em `otel-collector-opentelemetry-collector.monitoring:8888`

### Dashboard Customizado

O dashboard `togglemaster-overview.json` centraliza a saude do ecossistema:

| Secao | Paineis |
|-------|---------|
| **Cluster Health** | CPU por namespace, Memoria por namespace, Running Pods, Node CPU % (por node IP), Node Memory % (por node IP), Total Pods |
| **Microsservicos** | HTTP Request Rate por servico (Go + Python), HTTP Error Rate 5xx, HTTP Latency P95 (Python convertido de ms para s), Pod Restarts |
| **Logs (Real-Time)** | Todos os logs do namespace `togglemaster`, Filtro de logs de erro |

**Nota tecnica**: O UID do datasource Loki e aleatorio por instalacao do Grafana. O script `install-monitoring.sh` resolve o UID dinamicamente via API do Grafana antes de carregar o dashboard como ConfigMap.

---

## 4. Loki + Promtail

### Coleta de Logs

```
                                   Caminho principal
Pod (stdout/stderr) ──> Promtail (DaemonSet) ──> Loki ──> Grafana
      via /var/log/pods

                                   Caminho complementar (logs estruturados)
Aplicacao (OTel SDK) ──> OTel Collector ──> Loki (via OTLP/HTTP)
```

Dois caminhos de coleta:
1. **Promtail** (DaemonSet): coleta logs nativos dos conteineres via `/var/log/pods` — caminho principal
2. **OTel Collector**: recebe logs estruturados enviados via OTLP pelas aplicacoes — caminho complementar

### Loki - Modo Single Binary

Loki roda em modo **SingleBinary** (1 replica) para simplicidade:
- Sem persistence (emptyDir) — dados perdidos se o pod reiniciar
- Auth desabilitada (`auth_enabled: false`)
- Retencao de 72 horas
- Gateway, caches e canary desabilitados para economia de pods

### Consulta no Grafana (LogQL)

```logql
# Todos os logs do togglemaster
{namespace="togglemaster"}

# Apenas erros
{namespace="togglemaster"} |~ "(?i)(error|fatal|panic|exception|traceback)"

# Logs de um servico especifico
{namespace="togglemaster", app="auth-service"}

# Logs formatados com nome do pod
{namespace="togglemaster"} | line_format "{{.pod}} {{.stream}}: {{__line__}}"
```

---

## 5. Alertas e Resposta a Incidentes

### Regras de Alerta (PrometheusRules)

| Alerta | Condicao | Severidade | For |
|--------|---------|------------|-----|
| `HighErrorRate5xx` | Taxa de 5xx > 5% em qualquer servico | critical | 2min |
| `HighErrorRate5xxAuth` | Taxa de 5xx > 5% no auth-service | critical | 2min |
| `PodCrashLooping` | > 3 restarts em 15min | warning | 5min |
| `PodNotReady` | Pod nao ready (exclui jobs Completed) | warning | 5min |
| `HighCPUUsage` | CPU > 90% do limite | warning | 5min |
| `HighMemoryUsage` | Memoria > 90% do limite | warning | 5min |

### Roteamento (Alertmanager)

```
Alerta Prometheus
  │
  ├── severity: critical ──> PagerDuty (incidente) + Discord
  │
  ├── severity: warning ───> Discord
  │
  ├── Watchdog ────────────> Silenciado (heartbeat, nao acionavel)
  │
  └── KubeControllerManagerDown ──> Silenciado (esperado no EKS gerenciado)
```

**Integracao Discord**: O Alertmanager usa `slack_configs` com o sufixo `/slack` na URL do webhook do Discord. Discord nao aceita o formato JSON nativo do Alertmanager (retorna "Cannot send an empty message"), mas aceita o formato Slack-compatible.

**Integracao PagerDuty**: Usa Events API v2 com `routing_key` (Integration Key do servico). Alertas criticos criam incidentes automaticamente. O `dedup_key` e gerado pelo Alertmanager baseado no fingerprint do alerta.

### Fluxo de Self-Healing

```
1. Prometheus detecta condicao de alerta (ex: HighErrorRate5xx)
2. Alerta fica "Pending" por 2 minutos (campo "for")
3. Alerta muda para "Firing"
4. Alertmanager recebe e roteia:
   a. PagerDuty: cria incidente critico
   b. Discord: envia notificacao via Slack-compatible webhook
   c. GitHub API: POST /repos/<GITHUB_USER>/TC4-ToggleMaster/dispatches
      { "event_type": "self-healing",
        "client_payload": { "service": "auth-service", "alert": "HighErrorRate5xx" } }
5. GitHub Actions dispara workflow self-healing.yaml
6. Workflow:
   a. Configura AWS + kubectl (usando GitHub Secrets)
   b. kubectl rollout restart deployment/auth-service -n togglemaster
   c. Aguarda rollout status
   d. Notifica Discord com resultado (sucesso/falha)
7. Pods sao recriados com nova instancia
8. Health checks passam -> servico restaurado
9. Alerta muda para "Resolved"
10. Alertmanager envia notificacao de resolucao para PagerDuty + Discord
```

### Testar Alertas Manualmente

```bash
# Enviar alerta de teste diretamente ao Alertmanager
kubectl exec -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -qO- --post-data='[{
  "status": "firing",
  "labels": {
    "alertname": "TestAlert",
    "severity": "warning",
    "team": "togglemaster"
  },
  "annotations": {
    "summary": "Alerta de teste",
    "description": "Validando pipeline de notificacao."
  }
}]' --header='Content-Type: application/json' http://localhost:9093/api/v2/alerts

# Resolver (enviar mesmo payload com "status": "resolved")
```

---

## 6. New Relic APM

### O que e visivel no New Relic

| Funcionalidade | Descricao |
|---------------|-----------|
| **Service Map** | Mapa visual das dependencias entre os 5 microsservicos |
| **Distributed Tracing** | Trace completo de uma requisicao passando por multiplos servicos |
| **Error Analytics** | Analise de erros agrupados por tipo, endpoint e servico |
| **Transactions** | Performance de cada endpoint (throughput, latencia, error rate) |
| **Databases** | Queries SQL lentas ou frequentes (via instrumentacao psycopg2) |

### Exemplo de Trace Distribuido

```
[evaluation-service] POST /evaluate (120ms)
  ├── [flag-service] GET /flags/my-feature (35ms)
  │     └── [auth-service] GET /validate (12ms)
  │           └── PostgreSQL SELECT (3ms)
  ├── [targeting-service] GET /rules/1 (28ms)
  │     └── [auth-service] GET /validate (10ms)
  │           └── PostgreSQL SELECT (2ms)
  ├── Redis GET (2ms)
  └── SQS SendMessage (15ms)
```

---

## 7. Arquitetura Completa (Diagrama)

```
                          ┌─────────────────────────────────────────┐
                          │              EKS Cluster                 │
                          │           (3x t3.medium)                │
┌──────────┐              │                                         │
│ Discord  │◄─slack/http──┤  ┌───────────────────────────────┐      │
│ Channel  │              │  │       Alertmanager             │      │
└──────────┘              │  │  critical -> PagerDuty+Discord │      │
                          │  │  warning  -> Discord           │      │
┌──────────┐              │  └──────────┬────────────────────┘      │
│PagerDuty │◄─events v2───┤             │                           │
│Incidents │              │  ┌──────────┴────────────────────┐      │
└──────────┘              │  │        Prometheus              │      │
                          │  │   PrometheusRules (alertas)    │      │
┌──────────┐              │  │   Scrape: node-exporter,       │      │
│ GitHub   │◄─dispatch────┤  │   kube-state-metrics, otel     │      │
│ Actions  │              │  └──────────┬────────────────────┘      │
│(healing) │              │             │ remote write               │
└──────────┘              │  ┌──────────┴────────────────────┐      │
                          │  │      OTel Collector            │      │
┌──────────┐              │  │  traces  -> New Relic          │      │
│New Relic │◄─otlp/http───┤  │  metrics -> Prometheus         │      │
│  APM     │              │  │  logs    -> Loki               │      │
└──────────┘              │  └──────────┬────────────────────┘      │
                          │             │ otlp (gRPC :4317 / HTTP :4318) │
                          │  ┌──────────┴────────────────────┐      │
                          │  │      Microsservicos            │      │
                          │  │  auth-service (Go)        x2   │      │
                          │  │  evaluation-service (Go)  x2   │      │
                          │  │  flag-service (Python)    x2   │      │
                          │  │  targeting-service (Py)   x2   │      │
                          │  │  analytics-service (Py)   x2   │      │
                          │  └───────────┬───────────────────┘      │
                          │              │ stdout/stderr              │
                          │  ┌───────────┴───────────────────┐      │
                          │  │  Promtail (DaemonSet) -> Loki  │      │
                          │  └───────────────────────────────┘      │
                          │                                         │
                          │  ┌───────────────────────────────┐      │
                          │  │         Grafana                │      │
                          │  │  Datasources: Prometheus, Loki │      │
                          │  │  Dashboard: Ecosystem Health   │      │
                          │  └───────────────────────────────┘      │
                          │                                         │
                          │  ┌───────────────────────────────┐      │
                          │  │         ArgoCD                 │      │
                          │  │  7 Applications (Synced)       │      │
                          │  │  GitOps: git -> cluster state  │      │
                          │  └───────────────────────────────┘      │
                          └─────────────────────────────────────────┘
```
