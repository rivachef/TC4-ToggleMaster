# ToggleMaster - Phase 4: Observability & Self-Healing

**Tech Challenge | FIAP Pos Tech | DevOps & Software Architecture | 2026**

---

## 1. Architecture Overview

ToggleMaster is a feature flag platform composed of 5 microservices running on AWS EKS:

- **auth-service** (Go, port 8001) - Authentication and API key management
- **flag-service** (Python, port 8002) - Feature flag CRUD operations
- **targeting-service** (Python, port 8003) - User targeting rules
- **evaluation-service** (Go, port 8004) - Real-time flag evaluation
- **analytics-service** (Python, port 8005) - Usage analytics and metrics

**Infrastructure:**
- EKS Cluster: 3 nodes (t3.medium) across 2 Availability Zones
- Terraform IaC: VPC, EKS, RDS PostgreSQL, ElastiCache Redis, SQS, ECR
- ArgoCD GitOps: auto-sync with self-heal and prune enabled
- 2 replicas per service = 10 pods total

---

## 2. Monitoring Stack Components

All deployed via Helm charts in the `monitoring` namespace (16 pods total):

| Component | Role | Details |
|-----------|------|---------|
| **Prometheus** | Time-series metrics database | Stores CPU, memory, HTTP rates, histograms |
| **Loki** | Log aggregation system | Centralizes all container logs |
| **Promtail** | Log collector (DaemonSet) | Runs on each node, tails and ships logs to Loki |
| **Grafana** | Visualization & dashboards | Single pane of glass for metrics + logs |
| **OTel Collector** | Central telemetry router | Receives, processes, and exports all telemetry data |

---

## 3. OTel Collector - The Central Router

The OpenTelemetry Collector is the heart of the observability pipeline. All 5 microservices send telemetry to it via OTLP protocol.

**Input:** Apps send data via gRPC (port 4317) and HTTP (port 4318)

**Output pipelines:**
- **Traces** → New Relic (via OTLP HTTP)
- **Metrics** → Prometheus (via remote write) + New Relic
- **Logs** → Loki

**Why OTel Collector?** It decouples applications from observability backends. Apps only know about the OTel endpoint - they have zero knowledge of Prometheus, Loki, or New Relic. To swap backends, change one config file, zero code changes.

---

## 4. Grafana Dashboard - Ecosystem Health

Custom dashboard: "ToggleMaster - Ecosystem Health"

| Panel | Data Source | Description |
|-------|-------------|-------------|
| Node CPU % | Prometheus | Per-node gauge with label_replace |
| Node Memory % | Prometheus | Per-node gauge, IP without port |
| HTTP Request Rate | Prometheus | By service (Go + Python metrics combined) |
| HTTP Error Rate 5xx | Prometheus | By service, filtered by error status codes |
| HTTP Latency P95 | Prometheus | 95th percentile response time |
| Live Logs | Loki | Real-time container logs stream |
| Error Logs Only | Loki | Filtered by error/warn keywords |
| Active Pods | Prometheus | Pod count per deployment |

**Important:** Go services emit `http_server_request_duration_seconds` while Python services emit `http_server_duration_milliseconds` - the dashboard handles both metric names.

---

## 5. APM - New Relic

### Distributed Tracing
Follow a single request across all 5 services. See exactly where time is spent:
- auth-service (12ms) → flag-service (8ms) → evaluation-service (45ms) → targeting-service (15ms)

### Service Map
Visual dependency graph showing:
- Which service calls which
- Latency on each edge
- Error rates per connection
- Health status per service

### Why New Relic?
- Free education tier (100GB/month ingest)
- Native OTLP ingest - no proprietary agent needed
- Service Map built automatically from OTel traces

---

## 6. Alerting Pipeline

### PrometheusRules (Custom Alert Rules)

| Alert | Severity | Trigger |
|-------|----------|---------|
| HighErrorRate5xx | CRITICAL | >5% 5xx error rate for 5 min |
| HighErrorRate5xxAuth | CRITICAL | >5% 5xx on auth-service for 5 min |
| PodCrashLooping | WARNING | Pod restart count > 3 in 15 min |
| PodNotReady | WARNING | Pod not ready for 5 min |
| HighCPUUsage | WARNING | CPU > 80% for 10 min |
| HighMemoryUsage | WARNING | Memory > 85% for 10 min |

### Alertmanager Routing

| Severity | Destination |
|----------|-------------|
| CRITICAL | PagerDuty + Discord + Self-Healing webhook |
| WARNING | Discord only |
| SILENCED | Watchdog (heartbeat), KubeControllerManagerDown (managed EKS) |

Discord receives alerts via Slack-compatible webhook format (URL with `/slack` suffix).

---

## 7. Self-Healing - Automated Remediation

### Architecture Flow
1. **Fault occurs** → Pod goes down or becomes unhealthy
2. **Prometheus detects** → PrometheusRule fires alert
3. **Alertmanager routes** → Sends webhook to GitHub API (repository_dispatch)
4. **GitHub Actions runs** → Self-Healing workflow triggers
5. **Auto-remediate** → `kubectl rollout restart` on affected service
6. **Notification** → Discord receives "Self-Healing SUCCESS" message

### Live Demo Steps
1. `kubectl scale deployment/auth-service -n togglemaster --replicas=0` (inject fault)
2. Show pods going to 0
3. Trigger: `gh workflow run "Self-Healing" -f service=auth-service -f alert=PodNotReady`
4. Watch GitHub Actions workflow execute (configure AWS → kubectl → rollout restart)
5. Show pods coming back (2 replicas restored by HPA)
6. Show Discord notification: "Self-Healing SUCCESS"

---

## 8. Resilience Features

| Feature | Scope | Configuration |
|---------|-------|---------------|
| **HPA** (Horizontal Pod Autoscaler) | All 5 services | 2-5 replicas, CPU target 70% |
| **PDB** (Pod Disruption Budget) | All 5 services | minAvailable: 1 |
| **Health Probes** | All 5 services | Liveness + Readiness on /health |
| **Replicas** | All 5 services | 2 replicas each (high availability) |
| **Multi-AZ** | EKS Cluster | 3 nodes across 2 Availability Zones |

Defense in depth: HPA scales under load, PDB prevents disruptions during maintenance, probes detect and restart unhealthy pods, 2 replicas ensure zero downtime during rolling updates.

---

## 9. Technical Justifications

### New Relic over Datadog
- Free education tier: 100GB/month data ingest
- Native OTLP ingest: no proprietary agent needed in containers
- Service Map automatically built from OTel trace data

### PagerDuty over OpsGenie
- Simpler Events API v2 for Alertmanager integration
- Better free tier for students
- Direct `pagerduty_configs` support in Alertmanager

### OTel Collector over Direct Export
- Vendor-neutral OpenTelemetry standard
- Single configuration point for all backends
- Swap New Relic for Datadog = change 1 exporter line, zero code changes

---

## 10. Repository & Reproducibility

### Fully Forkable
- Manifests use `<AWS_ACCOUNT_ID>` and `<GITHUB_USER>` placeholders
- `setup-full.sh` replaces them automatically, commits, and pushes

### One-Command Deploy
```
terraform apply + ./scripts/setup-full.sh
```
Provisions infrastructure, builds Docker images, deploys all apps, installs full monitoring stack.

### Clean Teardown
```
./scripts/destroy-all.sh
```
Destroys all AWS resources, restores placeholders, commits back to repo. Battle-tested and fixed for macOS compatibility.

---

## Summary

| Achievement | Description |
|-------------|-------------|
| **Full Observability** | Metrics + Logs + Traces across all 5 services |
| **Automated Alerting** | PagerDuty (critical) + Discord (all) with smart routing |
| **Self-Healing** | Fault detection → auto-remediation via GitHub Actions |
| **Reproducible** | Everything as code, forkable, one-command deploy |

The complete observability pipeline: applications emit telemetry → OTel Collector routes it → Prometheus/Loki/New Relic store it → Grafana visualizes it → Alertmanager acts on it → GitHub Actions heals it → Discord notifies about it.
