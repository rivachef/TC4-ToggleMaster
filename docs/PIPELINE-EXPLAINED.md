# Arquitetura de Observabilidade - ToggleMaster Fase 4

Este documento explica a arquitetura do pipeline de telemetria implementado no ToggleMaster, como os dados fluem dos microsservicos ate os backends de observabilidade, e como os alertas e automacoes funcionam.

---

## Visao Geral

O ToggleMaster utiliza o **OpenTelemetry** como padrao de instrumentacao e o **OTel Collector** como hub central de telemetria. Os tres pilares da observabilidade sao cobertos:

| Pilar | Ferramenta | Backend |
|-------|-----------|---------|
| **Metricas** | OTel SDK + Prometheus | Prometheus (kube-prometheus-stack) |
| **Logs** | Promtail + OTel Collector | Loki |
| **Traces** | OTel SDK + OTel Collector | New Relic (APM) |

---

## 1. Instrumentacao dos Microsservicos

### Servicos Go (auth-service, evaluation-service)

Instrumentacao **manual** via OTel SDK:

```
main.go
  └── initTelemetry()          # telemetry.go
       ├── TracerProvider       # Exporta traces via OTLP gRPC
       ├── MeterProvider        # Exporta metricas via OTLP gRPC
       └── TextMapPropagator    # W3C TraceContext + Baggage

  └── otelMiddleware()          # otel_middleware.go
       ├── Extrai contexto do request (propagacao)
       ├── Cria span por requisicao HTTP
       ├── Registra metricas:
       │    ├── http_server_request_total (counter)
       │    └── http_server_request_duration_seconds (histogram)
       └── Propaga contexto para chamadas downstream
```

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

**Configuracao via variaveis de ambiente** (ConfigMap do K8s):
```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector-...monitoring:4317"
OTEL_SERVICE_NAME: "flag-service"
OTEL_RESOURCE_ATTRIBUTES: "service.namespace=togglemaster,deployment.environment=production"
OTEL_TRACES_EXPORTER: "otlp"
OTEL_METRICS_EXPORTER: "otlp"
```

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
      exporters: [otlp/newrelic, debug]            # -> New Relic

    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite, debug]    # -> Prometheus

    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [loki, debug]                     # -> Loki
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
| `loki` | Loki `:3100/loki/api/v1/push` | HTTP push |
| `otlp/newrelic` | `otlp.nr-data.net:4317` | gRPC (TLS) |

---

## 3. Prometheus + Grafana

### Prometheus (kube-prometheus-stack)

Inclui automaticamente:
- **Prometheus Server** - Armazenamento de metricas (7 dias retencao, 5 GB)
- **Alertmanager** - Roteamento de alertas
- **node-exporter** - Metricas de host (CPU, memoria, disco, rede)
- **kube-state-metrics** - Metricas do Kubernetes (pods, deployments, nodes)

### Dashboard Customizado

O dashboard `togglemaster-overview.json` centraliza a saude do ecossistema:

| Secao | Paineis |
|-------|---------|
| **Cluster Health** | CPU por namespace, Memoria por namespace, Running Pods, Node CPU %, Node Memory %, Total Pods |
| **Microsservicos** | HTTP Request Rate por servico, HTTP Error Rate 5xx por servico, HTTP Latency P95, Pod Restarts |
| **Logs (Real-Time)** | Todos os logs do namespace `togglemaster`, Filtro de logs de erro |

---

## 4. Loki + Promtail

### Coleta de Logs

```
Pod (stdout/stderr) --> Promtail (DaemonSet) --> Loki
                                                   |
Aplicacao (OTel SDK) --> OTel Collector ---------> Loki
```

Dois caminhos de coleta:
1. **Promtail** (DaemonSet): coleta logs nativos dos conteineres via `/var/log/pods`
2. **OTel Collector**: recebe logs estruturados enviados via OTLP pelas aplicacoes

### Consulta no Grafana

```logql
# Todos os logs do togglemaster
{namespace="togglemaster"}

# Apenas erros
{namespace="togglemaster"} |~ "(?i)(error|fatal|panic|exception|traceback)"

# Logs de um servico especifico
{namespace="togglemaster", app="auth-service"}
```

---

## 5. Alertas e Resposta a Incidentes

### Regras de Alerta (PrometheusRules)

| Alerta | Condicao | Severidade | For |
|--------|---------|------------|-----|
| `HighErrorRate5xx` | Taxa de 5xx > 5% | critical | 2min |
| `HighErrorRate5xxAuth` | Taxa de 5xx > 5% no auth-service | critical | 2min |
| `PodCrashLooping` | > 3 restarts em 15min | warning | 5min |
| `PodNotReady` | Pod nao ready | warning | 5min |
| `HighCPUUsage` | CPU > 90% do limite | warning | 5min |
| `HighMemoryUsage` | Memoria > 90% do limite | warning | 5min |

### Roteamento (Alertmanager)

```
Alerta Prometheus
  │
  ├── severity: critical ──> OpsGenie (P1) + Discord + Self-Healing
  │
  └── severity: warning ───> Discord
```

### Fluxo de Self-Healing

```
1. Prometheus detecta condicao de alerta
2. Alerta fica "Pending" por 2 minutos
3. Alerta muda para "Firing"
4. Alertmanager recebe e roteia:
   a. OpsGenie: cria incidente P1
   b. Discord: envia notificacao
   c. GitHub API: POST /repos/rivachef/TC4-ToggleMaster/dispatches
      { "event_type": "self-healing",
        "client_payload": { "service": "auth-service", "alert": "HighErrorRate5xx" } }
5. GitHub Actions dispara workflow self-healing.yaml
6. Workflow:
   a. Configura AWS + kubectl
   b. kubectl rollout restart deployment/auth-service -n togglemaster
   c. Aguarda rollout status
   d. Notifica Discord com resultado (sucesso/falha)
7. Pods sao recriados com nova instancia
8. Health checks passam -> servico restaurado
9. Alerta muda para "Resolved"
10. Alertmanager envia notificacao de resolucao
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
