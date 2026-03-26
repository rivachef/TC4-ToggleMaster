# ToggleMaster - Tech Challenge Fase 3

Plataforma de Feature Flags com 5 microsservicos, infraestrutura automatizada via Terraform, CI/CD com DevSecOps (GitHub Actions) e GitOps (ArgoCD).

**Repositorio:** [github.com/rivachef/TC3-ToggleMaster](https://github.com/rivachef/TC3-ToggleMaster)

> **Nota:** Os manifestos em `gitops/` e `argocd/` usam placeholders (`<AWS_ACCOUNT_ID>`, `<GITHUB_USER>`) que sao substituidos automaticamente pelo script `setup-full.sh` durante o setup.

---

## Estrutura do Projeto

```
TC3-ToggleMaster/
├── terraform/              # IaC - Infraestrutura AWS (VPC, EKS, RDS, Redis, SQS, DynamoDB, ECR)
│   ├── main.tf             # Orquestracao dos modulos
│   ├── backend.tf          # Backend remoto S3 + DynamoDB lock
│   ├── variables.tf        # Variaveis do projeto
│   ├── outputs.tf          # Outputs dos recursos criados
│   ├── providers.tf        # Provider AWS
│   ├── terraform.tfvars.example  # Exemplo de variaveis
│   └── modules/
│       ├── networking/     # VPC, Subnets, IGW, NAT, Route Tables, Security Groups
│       ├── eks/            # Cluster EKS + Node Group (com LabRole)
│       ├── databases/      # 3x RDS PostgreSQL + Redis + DynamoDB
│       ├── messaging/      # Fila SQS
│       └── ecr/            # 5 repositorios ECR
├── microservices/          # Codigo fonte dos 5 microsservicos
│   ├── auth-service/       # Go 1.21 - Gerenciamento de API keys (porta 8001)
│   ├── flag-service/       # Python 3.12 - CRUD de feature flags (porta 8002)
│   ├── targeting-service/  # Python 3.12 - Regras de segmentacao (porta 8003)
│   ├── evaluation-service/ # Go 1.21 - Avaliacao de flags em tempo real (porta 8004)
│   └── analytics-service/  # Python 3.12 - Analytics via SQS/DynamoDB (porta 8005)
├── gitops/                 # Manifestos Kubernetes monitorados pelo ArgoCD
│   ├── namespace.yaml      # Namespace togglemaster
│   ├── ingress.yaml        # NGINX Ingress rules
│   ├── auth-service/       # Deployment, Service, DB init (Job + ConfigMap + Secret)
│   ├── flag-service/       # Deployment, Service, DB init
│   ├── targeting-service/  # Deployment, Service, DB init
│   ├── evaluation-service/ # Deployment, Service, HPA
│   └── analytics-service/  # Deployment, Service
├── argocd/                 # Configuracao do ArgoCD
│   ├── applications.yaml   # AppProject + 6 Applications
│   └── install.sh          # Script de instalacao do ArgoCD
├── .github/workflows/      # Pipelines CI/CD com DevSecOps
│   ├── ci-auth-service.yaml
│   ├── ci-flag-service.yaml
│   ├── ci-targeting-service.yaml
│   ├── ci-evaluation-service.yaml
│   └── ci-analytics-service.yaml
├── scripts/                # Scripts de automacao
│   ├── setup-full.sh       # Setup completo (orquestra tudo)
│   ├── generate-secrets.sh # Gera secrets a partir do Terraform output
│   ├── apply-secrets.sh    # Aplica secrets no cluster K8s
│   ├── generate-api-key.sh # Gera SERVICE_API_KEY via auth-service
│   └── update-aws-credentials.sh  # Renova creds AWS (a cada 4h)
└── docs/                   # Documentacao do projeto
    ├── ROTEIRO-COMPLETO.md
    ├── RESUMO-EXECUTIVO.md
    └── GUIA-APRESENTACAO.md
```

---

## Pre-requisitos

| Ferramenta | Versao Minima | Finalidade |
|------------|--------------|------------|
| AWS CLI | v2 | Acesso a AWS |
| Terraform | >= 1.5 | Provisionamento de infra |
| kubectl | >= 1.28 | Gerenciamento do cluster |
| Docker | >= 24 | Build de imagens |
| Git | >= 2.0 | Versionamento |

**AWS Academy:** Sessao ativa com credenciais temporarias (4h de duracao). Para renovar credenciais no cluster: `./scripts/update-aws-credentials.sh`.

---

## Guia Rapido - Subir o Ambiente do Zero

### Passo 1: Configurar credenciais AWS

**Opcao A — Variaveis de ambiente:**
```bash
export AWS_ACCESS_KEY_ID="<seu-access-key>"
export AWS_SECRET_ACCESS_KEY="<seu-secret-key>"
export AWS_SESSION_TOKEN="<seu-session-token>"
export AWS_DEFAULT_REGION="us-east-1"
```

**Opcao B — Via `aws configure`:**
```bash
aws configure
# Informar: Access Key, Secret Key, Region (us-east-1), Output (json)
aws configure set aws_session_token "<seu-session-token>"
```

Verificar:
```bash
aws sts get-caller-identity
```

### Passo 2: Criar backend remoto (apenas primeira vez)

```bash
aws s3 mb s3://togglemaster-terraform-state --region us-east-1

aws dynamodb create-table \
  --table-name togglemaster-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Passo 3: Provisionar infraestrutura com Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Editar `terraform.tfvars`:
```hcl
aws_region   = "us-east-1"
project_name = "togglemaster"
lab_role_arn = "arn:aws:iam::<SEU_ACCOUNT_ID>:role/LabRole"
db_password  = "<SUA_SENHA_SEGURA>"
```

```bash
terraform init
terraform plan            # Revisar 39 recursos
terraform apply -auto-approve   # ~15-20 min
```

> **Nota:** Se `terraform init` falhar com erro de digest, limpar o lock no DynamoDB:
> ```bash
> aws dynamodb delete-item --table-name togglemaster-terraform-lock \
>   --key '{"LockID":{"S":"togglemaster-terraform-state/infra/terraform.tfstate-md5"}}'
> terraform init -reconfigure
> ```

### Passo 4: Build e push das imagens Docker

```bash
# Definir variaveis
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Login no ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build e push dos 5 servicos
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo ">>> Building $svc..."
  docker build --platform linux/amd64 -t $ECR_REGISTRY/$svc:latest microservices/$svc
  docker push $ECR_REGISTRY/$svc:latest
done
```

### Passo 5: Configurar kubectl

```bash
aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
kubectl get nodes   # Deve mostrar 2 nodes Ready
```

### Passo 6: Setup automatizado (ArgoCD + Secrets + Deploy)

Opcao A — **Setup completo automatizado** (recomendado):
```bash
./scripts/setup-full.sh
```
Este script executa 8 passos: gera secrets a partir do Terraform output, instala ArgoCD, aplica secrets no cluster, faz build/push das imagens Docker no ECR (se necessario), cria as ArgoCD Applications, instala NGINX Ingress e gera a SERVICE_API_KEY.

> **Nota:** Se usar Opcao A, o Passo 4 (Docker build) pode ser pulado — o script detecta se as imagens ja existem no ECR e faz o build automaticamente se necessario.

Opcao B — **Passo a passo manual**:
```bash
# 6a. Gerar secrets a partir do Terraform output
./scripts/generate-secrets.sh

# 6b. Instalar ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# 6c. Aplicar secrets no cluster
./scripts/apply-secrets.sh

# 6d. Aplicar ArgoCD Applications
kubectl apply -f argocd/applications.yaml

# 6e. Instalar NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml

# 6f. Aguardar pods e gerar API key
kubectl get pods -n togglemaster -w
./scripts/generate-api-key.sh
```

> **Nota:** Os secrets Kubernetes sao gerenciados fora do git (via `stringData`, sem base64 manual). O script `generate-secrets.sh` le automaticamente o `terraform output` e as credenciais AWS (suporta env vars e `aws configure`). Os arquivos `secret.yaml` gerados estao no `.gitignore`.

### Passo 7: Verificar tudo rodando

```bash
# Todos os pods devem estar Running (10 pods + 3 jobs Completed)
kubectl get pods -n togglemaster

# Verificar health dos servicos
kubectl port-forward svc/auth-service 8001:8001 -n togglemaster &
curl http://localhost:8001/health

# Acessar ArgoCD
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

### Passo 8: Configurar GitHub Secrets para CI/CD

No GitHub: Settings > Secrets and variables > Actions:

| Secret | Valor |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | Access Key da sessao |
| `AWS_SECRET_ACCESS_KEY` | Secret Key |
| `AWS_SESSION_TOKEN` | Session Token |
| `ECR_REGISTRY` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com` |

> **IMPORTANTE:** Atualizar `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` a cada nova sessao AWS Academy.

---

## Pipeline CI/CD (DevSecOps)

Cada microsservico tem seu proprio workflow que dispara em push/PR na main:

```
Push (microservices/<service>/**)
  │
  ├── 1. Build & Unit Test
  │     Go: go build + go test
  │     Python: pip install + pytest
  │
  ├── 2. Linter / Static Analysis
  │     Go: golangci-lint v1.61
  │     Python: flake8
  │
  ├── 3. Security Scan (SAST & SCA)
  │     SCA: Trivy filesystem scan (CRITICAL + HIGH)
  │     SAST: gosec v2.20.0 (Go) / bandit (Python)
  │
  ├── 4. Docker Build & Push to ECR
  │     Build imagem → Trivy container scan → Push ECR (tag: <commit-sha>)
  │
  └── 5. Update GitOps Manifests
        Atualiza image tag em gitops/<service>/deployment.yaml
        Commit automatico via github-actions[bot]
```

---

## GitOps com ArgoCD

O ArgoCD monitora a pasta `gitops/` e sincroniza automaticamente:

| Application | Path | Descricao |
|-------------|------|-----------|
| auth-service | `gitops/auth-service` | Deployment + Service + DB init (Job/ConfigMap/Secret) |
| flag-service | `gitops/flag-service` | Deployment + Service + DB init |
| targeting-service | `gitops/targeting-service` | Deployment + Service + DB init |
| evaluation-service | `gitops/evaluation-service` | Deployment + Service + HPA |
| analytics-service | `gitops/analytics-service` | Deployment + Service |
| togglemaster-shared | `gitops/` | Namespace + Ingress |

**Sync Policy:** Automatico com `prune: true` e `selfHeal: true`.

---

## Variaveis de Ambiente por Servico

### auth-service
- `DATABASE_URL` - Connection string PostgreSQL
- `MASTER_KEY` - Chave mestra para criar API keys
- `PORT` - Porta (default: 8001)

### flag-service
- `DATABASE_URL` - Connection string PostgreSQL
- `AUTH_SERVICE_URL` - URL do auth-service para validacao
- `PORT` - Porta (default: 8002)

### targeting-service
- `DATABASE_URL` - Connection string PostgreSQL
- `AUTH_SERVICE_URL` - URL do auth-service
- `PORT` - Porta (default: 8003)

### evaluation-service
- `REDIS_ADDR` - Endpoint do Redis
- `FLAG_SERVICE_URL` - URL do flag-service
- `TARGETING_SERVICE_URL` - URL do targeting-service
- `SQS_QUEUE_URL` - URL da fila SQS
- `SERVICE_API_KEY` - API key gerada pelo auth-service
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` - Credenciais AWS
- `PORT` - Porta (default: 8004)

### analytics-service
- `SQS_QUEUE_URL` - URL da fila SQS
- `DYNAMODB_TABLE` - Nome da tabela DynamoDB
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` - Credenciais AWS
- `AWS_DEFAULT_REGION` - Regiao AWS
- `PORT` - Porta (default: 8005)

---

## Destruir o Ambiente

```bash
# 1. Remover ArgoCD Applications
kubectl delete -f argocd/applications.yaml

# 2. Remover ArgoCD
kubectl delete namespace argocd

# 3. Remover NGINX Ingress
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml

# 4. Destruir infraestrutura AWS
cd terraform
terraform destroy -auto-approve
```

---

## Documentacao Adicional

- [Roteiro Completo](docs/ROTEIRO-COMPLETO.md) - Passo a passo detalhado com todos os erros e fixes
- [Resumo Executivo](docs/RESUMO-EXECUTIVO.md) - Visao geral do projeto e conformidade com requisitos
- [Guia de Apresentacao](docs/GUIA-APRESENTACAO.md) - Roteiro para o video de demonstracao
