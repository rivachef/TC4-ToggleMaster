# Roteiro Completo - Setup ToggleMaster Fase 4

Guia passo-a-passo para configurar o ambiente completo do ToggleMaster com observabilidade, APM, alertas e self-healing.

---

## Pre-requisitos

- [ ] AWS CLI v2 configurado
- [ ] Terraform >= 1.5
- [ ] kubectl >= 1.28
- [ ] Helm >= 3.12
- [ ] Docker >= 24
- [ ] gh CLI >= 2.0
- [ ] Conta New Relic (free tier)
- [ ] Conta OpsGenie (free tier)
- [ ] Servidor Discord com canal de webhook

---

## Parte 1: Infraestrutura Base (Fase 3)

### 1.1 Credenciais AWS

```bash
export AWS_ACCESS_KEY_ID="<seu-access-key>"
export AWS_SECRET_ACCESS_KEY="<seu-secret-key>"
export AWS_SESSION_TOKEN="<seu-session-token>"
export AWS_DEFAULT_REGION="us-east-1"

# Verificar
aws sts get-caller-identity
```

### 1.2 Backend Remoto (apenas primeira vez)

```bash
aws s3 mb s3://togglemaster-terraform-state --region us-east-1

aws dynamodb create-table \
  --table-name togglemaster-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.3 Terraform Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars com lab_role_arn e db_password

terraform init
terraform plan       # Revisar 39 recursos
terraform apply -auto-approve  # ~15-20 min
```

### 1.4 Configurar kubectl

```bash
aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
kubectl get nodes    # 2 nodes Ready
```

---

## Parte 2: Setup Automatizado

O script `setup-full.sh` executa **10 passos** automaticamente:

```bash
./scripts/setup-full.sh
```

| Passo | Acao |
|-------|------|
| 1 | Gerar secrets a partir do Terraform output |
| 2 | Instalar ArgoCD |
| 3 | Aplicar secrets no cluster |
| 4 | Build e push das imagens Docker (ECR) |
| 5 | Aplicar ArgoCD Applications |
| 6 | Instalar NGINX Ingress Controller |
| 7 | Aguardar pods ficarem prontos |
| 8 | Gerar SERVICE_API_KEY |
| 9 | **Instalar Monitoring Stack** (Prometheus + Loki + Grafana + OTel Collector) |
| 10 | **Aplicar New Relic secret** (se existir) |

---

## Parte 3: Configuracao do APM (New Relic)

### 3.1 Criar conta New Relic

1. Acesse https://newrelic.com/signup
2. Crie uma conta gratuita (100 GB/mes)
3. No dashboard: Profile (canto inferior esquerdo) > API Keys
4. Copie a chave **INGEST - LICENSE**

### 3.2 Aplicar secret no cluster

```bash
cp gitops/monitoring/newrelic-secret.yaml.example gitops/monitoring/newrelic-secret.yaml

# Editar com sua license key
# stringData.license-key: "SUA_CHAVE_AQUI"

kubectl apply -f gitops/monitoring/newrelic-secret.yaml

# Reiniciar OTel Collector para carregar a nova chave
kubectl rollout restart deployment/otel-collector-opentelemetry-collector -n monitoring
```

### 3.3 Verificar no New Relic

1. Acesse https://one.newrelic.com
2. Navegue para APM & Services
3. Os 5 microsservicos devem aparecer (apos receber traces)
4. Clique em "Service Map" para ver o mapa de dependencias

---

## Parte 4: Configuracao de Alertas

### 4.1 Verificar regras de alerta

As PrometheusRules sao aplicadas automaticamente pelo Helm:

```bash
kubectl get prometheusrules -n monitoring
# togglemaster-alerts deve estar listado

# Verificar no Grafana: Alerting > Alert Rules
```

### 4.2 Configurar OpsGenie

1. Crie conta em https://www.atlassian.com/software/opsgenie
2. Settings > Integration List > Add Integration > API
3. Copie a API Key

### 4.3 Configurar Discord Webhook

1. No seu servidor Discord, va em: Configuracoes do Canal > Integracoes > Webhooks
2. Crie um webhook e copie a URL

### 4.4 Configurar Alertmanager

Edite o arquivo de configuracao com suas chaves:

```bash
# O arquivo alertmanager-config.yaml e um template
# Substitua os placeholders:
#   <OPSGENIE_API_KEY>     -> Sua chave OpsGenie
#   <DISCORD_WEBHOOK_URL>  -> URL do webhook Discord
#   <GITHUB_PAT_TOKEN>     -> Token de acesso GitHub (para self-healing)
```

---

## Parte 5: Configuracao do Self-Healing

### 5.1 GitHub Secrets

No GitHub (Settings > Secrets and variables > Actions), configure:

| Secret | Valor | Funcao |
|--------|-------|--------|
| `AWS_ACCESS_KEY_ID` | Access Key | kubectl no cluster |
| `AWS_SECRET_ACCESS_KEY` | Secret Key | kubectl no cluster |
| `AWS_SESSION_TOKEN` | Session Token | kubectl no cluster |
| `DISCORD_WEBHOOK_URL` | URL do webhook | Notificacao self-healing |

### 5.2 Testar Self-Healing Manualmente

```bash
# Via gh CLI
./scripts/self-healing/test-self-healing.sh auth-service

# Ou via GitHub UI
# Actions > Self-Healing > Run workflow > Escolher servico
```

### 5.3 Testar Fluxo Completo (Fault Injection)

```bash
# Injetar falha
./scripts/self-healing/inject-fault.sh auth-service

# Monitorar:
# 1. Grafana: Alerting > Alert Rules (alerta fica "Firing" em ~2-5 min)
# 2. OpsGenie: Alert List (incidente P1 criado)
# 3. Discord: Notificacao recebida
# 4. GitHub Actions: Self-Healing workflow executado
# 5. kubectl: Pod reiniciado automaticamente
kubectl get pods -n togglemaster -w
```

---

## Parte 6: Verificacao Final

### Checklist de Funcionamento

```bash
# Microsservicos
kubectl get pods -n togglemaster        # 10 pods Running

# Monitoring
kubectl get pods -n monitoring          # Prometheus, Grafana, Loki, Promtail, OTel Collector

# Grafana
kubectl get svc prometheus-grafana -n monitoring
# Acessar via LoadBalancer URL | admin / togglemaster2024

# Dashboard customizado: ToggleMaster - Ecosystem Health
# Datasources: Prometheus + Loki configurados

# Alertas
kubectl get prometheusrules -n monitoring

# ArgoCD
kubectl get applications -n argocd
```

### Endpoints

| Servico | Acesso Interno |
|---------|---------------|
| Prometheus | `prometheus-kube-prometheus-prometheus.monitoring:9090` |
| Grafana | `prometheus-grafana.monitoring:80` (LoadBalancer) |
| Loki | `loki.monitoring:3100` |
| OTel Collector (gRPC) | `otel-collector-opentelemetry-collector.monitoring:4317` |
| OTel Collector (HTTP) | `otel-collector-opentelemetry-collector.monitoring:4318` |

---

## Renovacao de Credenciais AWS (a cada 4h)

```bash
# Atualizar env vars com novas credenciais, depois:
./scripts/update-aws-credentials.sh

# Atualizar GitHub Secrets tambem (para self-healing funcionar)
```
