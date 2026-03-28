# Roteiro Completo - Setup ToggleMaster Fase 4

Guia passo-a-passo para configurar o ambiente completo do ToggleMaster com observabilidade, APM, alertas e self-healing.

---

## Pre-requisitos

### Ferramentas

- [ ] AWS CLI v2 configurado
- [ ] Terraform >= 1.5
- [ ] kubectl >= 1.28
- [ ] Helm >= 3.12
- [ ] Docker Desktop (deve estar **rodando** antes de executar o setup)
- [ ] gh CLI >= 2.0
- [ ] python3 (necessario para resolucao dinamica do Loki UID no dashboard)

### Contas Externas (criar ANTES do deploy)

- [ ] **New Relic** (free tier - 100GB/mes): https://newrelic.com/signup
  - Obter chave INGEST-LICENSE em: Profile > API Keys
- [ ] **PagerDuty** (free tier - ate 5 usuarios): https://www.pagerduty.com/sign-up-free/
  - Criar servico > Integrations > Events API v2 > copiar Integration Key
  - Nota: Use email pessoal se o corporativo ja estiver em uso
- [ ] **Discord** webhook: Server Settings > Integrations > Webhooks > New Webhook > Copy URL
- [ ] **GitHub PAT** (Fine-grained): Settings > Developer Settings > Personal Access Tokens
  - Permissoes: Actions (R/W), Contents (R), Metadata (R)

> **OpsGenie foi descontinuado.** A Atlassian migrou o OpsGenie para o Jira Service Management.
> Usamos PagerDuty como alternativa gratuita para incident management.

### GitHub Secrets (configurar no repositorio)

No GitHub (Settings > Secrets and variables > Actions), configure:

| Secret | Valor | Funcao |
|--------|-------|--------|
| `AWS_ACCESS_KEY_ID` | Access Key | kubectl no cluster |
| `AWS_SECRET_ACCESS_KEY` | Secret Key | kubectl no cluster |
| `AWS_SESSION_TOKEN` | Session Token | kubectl no cluster |
| `DISCORD_WEBHOOK_URL` | URL do webhook | Notificacao self-healing |

---

## Limitacoes do AWS Academy (IMPORTANTE)

O AWS Academy impoe restricoes que afetam diretamente o deploy. Entenda antes de comecar:

### 1. Sem OIDC Provider (sem IRSA)

**O que e**: OIDC (OpenID Connect) permite que pods no Kubernetes assumam roles IAM automaticamente via IRSA (IAM Roles for Service Accounts). E como se cada pod tivesse seu proprio "cartao de acesso" para servicos AWS.

**Impacto**: Sem OIDC, nenhum pod consegue se autenticar com a AWS por conta propria. Isso afeta:
- EBS CSI Driver (nao consegue criar discos EBS)
- Qualquer servico que precise acessar S3, SQS, DynamoDB diretamente do pod

**Workaround**: Usamos a LabRole onde possivel e desabilitamos features que dependem de IRSA.

### 2. Sem Persistent Volumes (EBS)

**A cadeia que quebra**:
1. Kubernetes PVC pede um disco -> 2. StorageClass delega ao provisioner -> 3. EBS CSI Driver chama EC2 API -> 4. Precisa de credenciais IRSA -> 5. **OIDC nao existe** -> FALHA

**Impacto**: Prometheus e Loki nao conseguem armazenar dados em disco persistente. Se o pod reiniciar, metricas e logs sao perdidos.

**Workaround**: Usamos `emptyDir` (armazenamento efemero no node). Aceitavel para ambiente de demo/avaliacao. O EBS CSI Driver nao e instalado pois nao ha necessidade.

### 3. Limite de Pods por Node

**Como funciona**: Cada instancia EC2 tem um numero maximo de ENIs (interfaces de rede) e IPs por ENI. O limite de pods e calculado como:

```
Max Pods = (ENIs x IPs_por_ENI) - 1
```

| Tipo | ENIs | IPs/ENI | Max Pods | Custo/hr |
|------|------|---------|----------|----------|
| t3.medium | 3 | 6 | **17** | $0.0416 |
| t3.large | 3 | 12 | **35** | $0.0832 |

### 4. Credenciais Temporarias (4h)

As credenciais do AWS Academy expiram a cada 4 horas. Apos renovar no console, execute:
```bash
./scripts/update-aws-credentials.sh

# Atualizar GitHub Secrets tambem (para self-healing funcionar)
```

### 5. KubeControllerManagerDown (alerta permanente)

O alerta `KubeControllerManagerDown` sempre fica "firing" no EKS porque a AWS gerencia o control plane e nao expoe o kube-controller-manager ao Prometheus. Esse alerta e silenciado automaticamente na configuracao do Alertmanager (rota para receiver `null`).

---

## Dimensionamento do Cluster

### Contagem de Pods Necessarios (~39 total)

| Namespace | Componente | Pods |
|-----------|-----------|------|
| togglemaster | 5 servicos x 2 replicas | 10 |
| togglemaster | 3 db-init jobs (Completed) | 3 |
| monitoring | Prometheus, Alertmanager, Grafana, Operator, kube-state-metrics | 5 |
| monitoring | Loki, Promtail (DaemonSet x3), Loki Canary (DaemonSet x3) | 7 |
| monitoring | OTel Collector, Node Exporter (DaemonSet x3) | 4 |
| argocd | Server, Controller, Redis, Repo Server | 4 |
| kube-system | CoreDNS x2, kube-proxy (DS x3), aws-node (DS x3) | 8 |
| ingress-nginx | Controller + admission jobs | 3 |
| **Total** | | **~44** |

> **Nota**: EBS CSI Driver nao e instalado (economia de 4 pod slots), pois nao ha suporte a OIDC/IRSA no AWS Academy.

### Opcoes de Cluster

| Configuracao | Capacidade | Custo/hr | Margem |
|-------------|-----------|----------|--------|
| 2x t3.medium | 34 pods | $0.0832 | **INSUFICIENTE** |
| **3x t3.medium** | **51 pods** | **$0.1248** | **+7 pods** |
| 2x t3.large | 70 pods | $0.1664 | +26 pods |

**Escolha: 3x t3.medium** - Menor custo com capacidade suficiente para 2 replicas de cada servico.

---

## Parte 1: Infraestrutura Base

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
kubectl get nodes    # 3 nodes Ready
```

---

## Parte 2: Preparar Secrets (ANTES do setup-full.sh)

### 2.1 New Relic Secret

```bash
cp gitops/monitoring/newrelic-secret.yaml.example gitops/monitoring/newrelic-secret.yaml
# Editar: stringData.license-key: "SUA_CHAVE_INGEST_LICENSE"
```

### 2.2 Alertmanager Secret

```bash
cp gitops/monitoring/alerting/alertmanager-config.yaml gitops/monitoring/alerting/alertmanager-secret.yaml
# Editar alertmanager-secret.yaml:
#   <PAGERDUTY_INTEGRATION_KEY> -> Sua chave PagerDuty (Events API v2)
#   <DISCORD_WEBHOOK_URL>       -> URL do webhook Discord (3 ocorrencias, SEM o /slack no final)
#   <GITHUB_PAT_TOKEN>          -> Token GitHub (para self-healing)
```

> **IMPORTANTE sobre Discord**: O template ja adiciona `/slack` ao final da URL automaticamente.
> Discord nao aceita o formato JSON nativo do Alertmanager (erro "Cannot send an empty message").
> Usamos `slack_configs` do Alertmanager com o sufixo `/slack` na URL do webhook do Discord,
> que aceita o formato Slack-compatible.

---

## Parte 3: Setup Automatizado

> **IMPORTANTE**: Docker Desktop deve estar rodando antes de executar o script.

O script `setup-full.sh` executa **10 passos** automaticamente:

```bash
./scripts/setup-full.sh
```

| Passo | Acao |
|-------|------|
| 1 | Gerar secrets a partir do Terraform output |
| 2 | Instalar ArgoCD |
| 3 | Aplicar secrets no cluster |
| 4 | Build e push das imagens Docker (ECR) + **substituir placeholders e auto commit+push** |
| 5 | Aplicar ArgoCD Applications |
| 6 | Instalar NGINX Ingress Controller |
| 7 | Aguardar pods ficarem prontos |
| 8 | Gerar SERVICE_API_KEY |
| 9 | Criar namespace monitoring + aplicar secrets manuais (New Relic, Alertmanager) |
| 10 | Instalar Monitoring Stack (Prometheus + Loki + Promtail + OTel Collector + Dashboard + Alert Rules) |

### O que acontece no passo 4 (placeholders)

O repositorio usa placeholders nos manifestos GitOps:
- `<AWS_ACCOUNT_ID>` nos `deployment.yaml` (imagem ECR)
- `<GITHUB_USER>` no `applications.yaml` (URL do repositorio ArgoCD)

O script substitui esses placeholders com os valores reais, **faz commit e push automaticamente** para que o ArgoCD sincronize os valores corretos. Sem isso, os pods ficam com `InvalidImageName`.

O script `destroy-all.sh` faz o caminho inverso: restaura os placeholders e faz commit+push, deixando o repositorio limpo para o proximo deploy.

### O que acontece no passo 10 (monitoring)

O `install-monitoring.sh` executa:
1. Instala kube-prometheus-stack (Prometheus + Grafana + Alertmanager) via Helm
2. Instala Loki (log aggregation) via Helm
3. Instala Promtail (log collector DaemonSet) via Helm
4. Instala OpenTelemetry Collector via Helm
5. Aplica PrometheusRules customizadas (togglemaster-alerts)
6. **Resolve dinamicamente o UID do datasource Loki** no Grafana (UID e aleatorio por instalacao)
7. Cria ConfigMap com o dashboard "ToggleMaster - Ecosystem Health"

O script e **idempotente** - pode ser re-executado com seguranca se falhar no meio.

---

## Parte 4: Configuracao do APM (New Relic)

### 4.1 Verificar no New Relic

1. Acesse https://one.newrelic.com
2. Navegue para APM & Services
3. Os 5 microsservicos devem aparecer (apos receber traces)
4. Clique em "Service Map" para ver o mapa de dependencias

### 4.2 Como funciona

Os microsservicos enviam telemetria via OpenTelemetry SDK para o OTel Collector (porta 4317/gRPC), que distribui para 3 backends:

| Sinal | Pipeline | Destino |
|-------|----------|---------|
| **Traces** | apps -> OTel Collector -> OTLP | New Relic |
| **Metrics** | apps -> OTel Collector -> Remote Write | Prometheus |
| **Logs** | apps -> stdout/stderr -> Promtail -> | Loki |

### 4.3 Metricas por linguagem

Os servicos Go e Python emitem metricas com nomes diferentes:

| Linguagem | Servicos | Metrica HTTP | Status Code Label |
|-----------|----------|-------------|-------------------|
| Go | auth-service, evaluation-service | `http_server_request_duration_seconds` | `http_response_status_code` |
| Python | flag-service, targeting-service, analytics-service | `http_server_duration_milliseconds` | `http_status_code` |

O dashboard "Ecosystem Health" inclui queries para ambas as metricas automaticamente.

> **Nota**: As metricas chegam ao Prometheus via OTel Collector remote write, portanto **nao possuem label `namespace`**. O dashboard filtra por `service_name` em vez de `namespace`.

---

## Parte 5: Configuracao de Alertas

### 5.1 Regras de alerta customizadas

As PrometheusRules do ToggleMaster sao aplicadas automaticamente pelo `install-monitoring.sh`:

```bash
kubectl get prometheusrules -n monitoring
# togglemaster-alerts deve estar listado
```

| Alerta | Severidade | Condicao |
|--------|-----------|----------|
| HighErrorRate5xx | critical | >5% de erros 5xx por 2 min |
| PodCrashLooping | warning | >3 restarts em 15 min |
| PodNotReady | warning | Pod nao-ready por 5 min (exclui jobs completos) |
| HighCPUUsage | warning | >90% do CPU limit por 5 min |
| HighMemoryUsage | warning | >90% do memory limit por 5 min |

### 5.2 Roteamento de alertas

| Severidade | Destino |
|-----------|---------|
| critical | PagerDuty + Discord |
| warning | Discord |
| Watchdog | Silenciado (heartbeat) |
| KubeControllerManagerDown | Silenciado (esperado no EKS) |

### 5.3 Verificar PagerDuty

1. Acesse https://app.pagerduty.com
2. Va em Incidents - alertas criticos aparecem aqui
3. Pode configurar notificacoes por email/SMS/app

### 5.4 Verificar Discord

Alertas de warning e critical sao enviados via Slack-compatible webhook. Alertas resolvidos tambem enviam notificacao de "RESOLVED".

### 5.5 Testar alertas manualmente

```bash
# Enviar alerta de teste para o Alertmanager
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
    "description": "Este e um alerta de teste para validar o pipeline de notificacao."
  }
}]' --header='Content-Type: application/json' http://localhost:9093/api/v2/alerts

# Resolver o alerta de teste (trocar "firing" por "resolved")
```

---

## Parte 6: Configuracao do Self-Healing

### 6.1 Testar Self-Healing Manualmente

```bash
# Via gh CLI
./scripts/self-healing/test-self-healing.sh auth-service

# Ou via GitHub UI
# Actions > Self-Healing > Run workflow > Escolher servico
```

### 6.2 Testar Fluxo Completo (Fault Injection)

```bash
# Injetar falha
./scripts/self-healing/inject-fault.sh auth-service

# Monitorar:
# 1. Grafana: Alerting > Alert Rules (alerta fica "Firing" em ~2-5 min)
# 2. PagerDuty: Incidents (incidente critico criado)
# 3. Discord: Notificacao recebida
# 4. GitHub Actions: Self-Healing workflow executado
# 5. kubectl: Pod reiniciado automaticamente
kubectl get pods -n togglemaster -w
```

---

## Parte 7: Dashboard Grafana

### 7.1 Dashboard "ToggleMaster - Ecosystem Health"

O dashboard inclui os seguintes paineis:

**Cluster Health:**
- CPU Usage by Namespace (togglemaster + monitoring)
- Memory Usage by Namespace
- Pod Status (quantidade de pods Running)
- Node CPU % (por node, mostrando IP)
- Node Memory % (por node, mostrando IP)
- Cluster Pods Total

**Microservices:**
- HTTP Request Rate by Service (Go + Python metrics combinadas)
- HTTP Error Rate 5xx by Service
- HTTP Latency P95 by Service (Python convertido de ms para seconds)
- Pod Restarts (barras, por pod)

**Logs (Real-Time):**
- ToggleMaster Logs (Live) - todos os logs do namespace com formato pod + stream
- Error Logs Only - filtrado por `error|fatal|panic|exception|traceback`

### 7.2 Acessar Grafana

```bash
# URL via LoadBalancer
kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Credenciais: admin / togglemaster2024
```

### 7.3 Nota sobre o Loki UID

O Grafana atribui UIDs aleatorios aos datasources em cada instalacao. O `install-monitoring.sh` resolve o UID do Loki dinamicamente via API do Grafana antes de carregar o dashboard. Se por algum motivo os paineis de log nao funcionarem, edite o painel e selecione o datasource Loki manualmente.

---

## Parte 8: Verificacao Final

### Checklist de Funcionamento

```bash
# Microsservicos (5 servicos x 2 replicas = 10 pods Running)
kubectl get pods -n togglemaster

# Monitoring (~16 pods)
kubectl get pods -n monitoring

# Nodes (3 nodes Ready)
kubectl get nodes

# ArgoCD (7 apps Synced + Healthy)
kubectl get applications -n argocd

# Alertas customizados
kubectl get prometheusrules -n monitoring
# togglemaster-alerts deve estar listado

# Grafana dashboard
kubectl get configmaps -n monitoring -l grafana_dashboard
# togglemaster-dashboard deve estar listado
```

### Endpoints

| Servico | Acesso Interno |
|---------|---------------|
| Prometheus | `prometheus-kube-prometheus-prometheus.monitoring:9090` |
| Grafana | `prometheus-grafana.monitoring:80` (LoadBalancer) |
| Loki | `loki.monitoring:3100` |
| OTel Collector (gRPC) | `otel-collector-opentelemetry-collector.monitoring:4317` |
| OTel Collector (HTTP) | `otel-collector-opentelemetry-collector.monitoring:4318` |
| ArgoCD | `argocd-server.argocd:443` (LoadBalancer) |

### Acessar UIs

```bash
# Grafana (via LoadBalancer - ja exposto)
kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Credenciais: admin / togglemaster2024

# ArgoCD (via LoadBalancer - ja exposto)
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# User: admin
# Senha: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Renovacao de Credenciais AWS (a cada 4h)

```bash
# 1. Renovar no console AWS Academy (Start Lab)
# 2. Copiar novas credenciais
# 3. Atualizar env vars e ~/.aws/credentials
./scripts/update-aws-credentials.sh

# 4. Atualizar GitHub Secrets (para self-healing funcionar)
```

---

## Destruir o Ambiente

```bash
./scripts/destroy-all.sh
```

O script:
1. Remove recursos Kubernetes (LoadBalancers, namespaces, ArgoCD)
2. Limpa Security Groups e ENIs orfaos na AWS
3. Executa `terraform destroy`
4. **Restaura placeholders** nos manifestos e faz commit+push (repo limpo para proximo deploy)

---

## Troubleshooting - Problemas Conhecidos

### Docker nao iniciado
**Erro**: `Cannot connect to the Docker daemon`
**Fix**: Iniciar Docker Desktop antes de rodar `setup-full.sh`. O script e idempotente, basta re-executar.

### Pods em Pending (pod limit)
**Erro**: Pods ficam em `Pending` com evento `0/N nodes are available: Too many pods`
**Causa**: t3.medium tem limite de 17 pods por node. Com 3 nodes = 51 max.
**Fix**: Verificar contagem de pods (`kubectl get pods --all-namespaces -o wide | awk '{print $8}' | sort | uniq -c`). Se necessario, remover componentes nao essenciais ou escalar nodes.

### InvalidImageName nos pods
**Erro**: `InvalidImageName` com `<AWS_ACCOUNT_ID>` literal no nome da imagem.
**Causa**: Placeholders nao foram substituidos, ou nao foi feito commit+push apos substituicao.
**Fix**: O `setup-full.sh` agora faz commit+push automaticamente apos substituir placeholders. Se falhar, verificar se o git push funcionou.

### PVC Pending (sem EBS CSI/OIDC)
**Erro**: PersistentVolumeClaims ficam em `Pending` indefinidamente.
**Causa**: AWS Academy nao configura OIDC, entao EBS CSI Driver nao consegue criar volumes.
**Fix**: Desabilitar persistence para Prometheus e Loki (usar emptyDir). Ja configurado nos values.yaml atuais.

### Loki StatefulSet nao atualiza
**Erro**: `Forbidden: updates to statefulset spec for fields other than...`
**Causa**: Nao e possivel alterar volumeClaimTemplates de um StatefulSet existente.
**Fix**: `helm uninstall loki -n monitoring` e depois `helm install` novamente.

### OTel Collector - exporter 'loki' desconhecido
**Erro**: `unknown type: "loki"` no exporter do OTel Collector.
**Causa**: Versoes mais novas do chart removeram o exporter `loki` nativo.
**Fix**: Usar `otlphttp/loki` com endpoint `http://loki.monitoring.svc.cluster.local:3100/otlp`. Ja configurado.

### ArgoCD revertendo mudancas manuais
**Erro**: `kubectl scale --replicas=1` funciona mas volta para 2.
**Causa**: ArgoCD sincroniza o estado do git. Mudancas manuais via kubectl sao revertidas.
**Fix**: Sempre alterar no git e deixar ArgoCD sincronizar. Nunca fazer mudancas manuais no cluster que conflitem com o git.

### MASTER_KEY desatualizada
**Erro**: `generate-api-key.sh` retorna 401 Unauthorized.
**Causa**: `generate-secrets.sh` gera nova MASTER_KEY cada execucao, mas pods usam a versao anterior.
**Fix**: `kubectl rollout restart deployment/auth-service -n togglemaster` antes de gerar API key.

### Discord recebe "Cannot send an empty message"
**Erro**: Alertmanager webhook para Discord falha com erro 400.
**Causa**: Discord nao aceita o formato JSON nativo do Alertmanager.
**Fix**: Usar `slack_configs` com URL `<DISCORD_WEBHOOK_URL>/slack` em vez de `webhook_configs`. Ja configurado no template.

### Alertas nao chegam no Discord/PagerDuty
**Erro**: Alertas aparecem no Grafana mas nao sao notificados.
**Causa**: O secret do Alertmanager deve ter o nome exato `alertmanager-prometheus-kube-prometheus-alertmanager` (nome gerenciado pelo Helm).
**Fix**: Verificar nome do secret: `kubectl get secret -n monitoring | grep alertmanager`. O template `alertmanager-config.yaml` ja usa o nome correto.

### Logs nao aparecem no dashboard
**Erro**: Paineis de log mostram "No data" ou "Datasource not found".
**Causa**: O UID do datasource Loki e aleatorio por instalacao do Grafana.
**Fix**: O `install-monitoring.sh` resolve o UID dinamicamente. Se falhar, editar o painel no Grafana e selecionar o datasource Loki manualmente.

### Metricas HTTP mostram "No data"
**Erro**: Paineis de Request Rate, Error Rate, Latency vazios.
**Causa**: As metricas do OTel nao possuem label `namespace` (chegam via remote write). Go e Python usam nomes de metricas diferentes.
**Fix**: O dashboard usa queries sem filtro de namespace e inclui ambas metricas (Go: `http_server_request_duration_seconds`, Python: `http_server_duration_milliseconds`). Ja configurado.
