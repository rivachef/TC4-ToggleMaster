# Roteiro Completo - Setup ToggleMaster Fase 4

Guia passo-a-passo para configurar o ambiente completo do ToggleMaster com observabilidade, APM, alertas e self-healing.

---

## Pre-requisitos

### Ferramentas

- [ ] AWS CLI v2 configurado
- [ ] Terraform >= 1.5
- [ ] kubectl >= 1.28
- [ ] Helm >= 3.12
- [ ] Docker Desktop (deve estar rodando antes de executar o setup)
- [ ] gh CLI >= 2.0

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

**Workaround**: Usamos `emptyDir` (armazenamento efemero no node). Aceitavel para ambiente de demo/avaliacao.

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
```

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
| kube-system | CoreDNS x2, kube-proxy (DS x3), aws-node (DS x3), EBS CSI | 9 |
| ingress-nginx | Controller + admission jobs | 3 |
| **Total** | | **~45** |

### Opcoes de Cluster

| Configuracao | Capacidade | Custo/hr | Margem |
|-------------|-----------|----------|--------|
| 2x t3.medium | 34 pods | $0.0832 | **INSUFICIENTE** |
| **3x t3.medium** | **51 pods** | **$0.1248** | **+6 pods** |
| 2x t3.large | 70 pods | $0.1664 | +25 pods |

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
#   <DISCORD_WEBHOOK_URL>       -> URL do webhook Discord (3 ocorrencias)
#   <GITHUB_PAT_TOKEN>          -> Token GitHub (para self-healing)
```

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
| 4 | Build e push das imagens Docker (ECR) |
| 5 | Aplicar ArgoCD Applications |
| 6 | Instalar NGINX Ingress Controller |
| 7 | Aguardar pods ficarem prontos |
| 8 | Gerar SERVICE_API_KEY |
| 9 | Criar namespace monitoring + aplicar secrets manuais (New Relic, Alertmanager) |
| 10 | Instalar Monitoring Stack (Prometheus + Loki + Promtail + OTel Collector) |

O script e **idempotente** - pode ser re-executado com seguranca se falhar no meio.

---

## Parte 4: Configuracao do APM (New Relic)

### 4.1 Verificar no New Relic

1. Acesse https://one.newrelic.com
2. Navegue para APM & Services
3. Os 5 microsservicos devem aparecer (apos receber traces)
4. Clique em "Service Map" para ver o mapa de dependencias

### 4.2 Como funciona

O OTel Collector recebe traces dos microsservicos via OTLP (porta 4317/gRPC) e encaminha para:
- **Traces** -> New Relic (OTLP endpoint)
- **Metrics** -> Prometheus (remote write)
- **Logs** -> Loki (OTLP/HTTP)

---

## Parte 5: Configuracao de Alertas

### 5.1 Verificar regras de alerta

As PrometheusRules sao aplicadas automaticamente pelo Helm:

```bash
kubectl get prometheusrules -n monitoring
# togglemaster-alerts deve estar listado

# Verificar no Grafana: Alerting > Alert Rules
```

### 5.2 Verificar PagerDuty

1. Acesse https://app.pagerduty.com
2. Va em Incidents - alertas criticos aparecem aqui
3. Pode configurar notificacoes por email/SMS/app

### 5.3 Verificar Discord

Alertas de warning e info sao enviados via webhook para o canal configurado.

---

## Parte 6: Configuracao do Self-Healing

### 6.1 GitHub Secrets

No GitHub (Settings > Secrets and variables > Actions), configure:

| Secret | Valor | Funcao |
|--------|-------|--------|
| `AWS_ACCESS_KEY_ID` | Access Key | kubectl no cluster |
| `AWS_SECRET_ACCESS_KEY` | Secret Key | kubectl no cluster |
| `AWS_SESSION_TOKEN` | Session Token | kubectl no cluster |
| `DISCORD_WEBHOOK_URL` | URL do webhook | Notificacao self-healing |

### 6.2 Testar Self-Healing Manualmente

```bash
# Via gh CLI
./scripts/self-healing/test-self-healing.sh auth-service

# Ou via GitHub UI
# Actions > Self-Healing > Run workflow > Escolher servico
```

### 6.3 Testar Fluxo Completo (Fault Injection)

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

## Parte 7: Verificacao Final

### Checklist de Funcionamento

```bash
# Microsservicos (5 servicos x 2 replicas = 10 pods)
kubectl get pods -n togglemaster        # 10 pods Running

# Monitoring (~13 pods)
kubectl get pods -n monitoring

# Nodes (3 nodes Ready)
kubectl get nodes

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
| ArgoCD | `argocd-server.argocd:443` (port-forward 8080) |

### Acessar UIs

```bash
# Grafana (via LoadBalancer - ja exposto)
kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# ArgoCD (via port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443
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

## Troubleshooting - Problemas Conhecidos

### Docker nao iniciado
**Erro**: `Cannot connect to the Docker daemon`
**Fix**: Iniciar Docker Desktop antes de rodar `setup-full.sh`. O script e idempotente, basta re-executar.

### Pods em Pending (pod limit)
**Erro**: Pods ficam em `Pending` com evento `0/2 nodes are available: Too many pods`
**Causa**: 2x t3.medium = 34 pods max, insuficiente para o stack completo.
**Fix**: Escalar para 3 nodes (`terraform apply`) ou reduzir replicas temporariamente.

### InvalidImageName nos pods
**Erro**: `InvalidImageName` com `<AWS_ACCOUNT_ID>` literal no nome da imagem.
**Causa**: `setup-full.sh` substituiu placeholders localmente, mas ArgoCD sincroniza do git (onde ainda estavam os placeholders).
**Fix**: Commitar e pushar os deployment.yaml apos o setup. Na proxima vez, usar Kustomize/Helm para injecao de valores.

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
**Fix**: Usar `otlphttp/loki` com endpoint `http://loki.monitoring.svc.cluster.local:3100/otlp`.

### ArgoCD revertendo mudancas manuais
**Erro**: `kubectl scale --replicas=1` funciona mas volta para 2.
**Causa**: ArgoCD sincroniza o estado do git. Mudancas manuais via kubectl sao revertidas.
**Fix**: Sempre alterar no git e deixar ArgoCD sincronizar. Nunca fazer mudancas manuais no cluster que conflitem com o git.

### MASTER_KEY desatualizada
**Erro**: `generate-api-key.sh` retorna 401 Unauthorized.
**Causa**: `generate-secrets.sh` gera nova MASTER_KEY cada execucao, mas pods usam a versao anterior.
**Fix**: `kubectl rollout restart deployment/auth-service -n togglemaster` antes de gerar API key.

---

## Melhorias para o Proximo Deploy

### 1. Substituir sed por Kustomize

Atualmente o `setup-full.sh` usa `sed` para substituir placeholders nos deployment.yaml. Isso e fragil e causa o problema do `InvalidImageName`.

**Melhor abordagem**: Usar Kustomize overlays com patches por ambiente. ArgoCD tem suporte nativo.

### 2. Criar secrets antes do setup

Os secrets manuais (New Relic, PagerDuty, Discord) devem ser preparados ANTES de rodar o setup. O script agora aplica automaticamente se os arquivos existirem.

### 3. Considerar replicas no planejamento de capacidade

Sempre calcular o numero total de pods ANTES de definir o tamanho do cluster. Formula:
```
Nodes necessarios = ceil(Total_Pods / Max_Pods_por_Node)
```
