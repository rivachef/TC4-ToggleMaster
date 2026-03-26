# Roteiro Completo - Setup do Ambiente ToggleMaster Fase 3

Este documento descreve **passo a passo** tudo que foi necessario para subir o ambiente completo, incluindo erros encontrados e respectivas correcoes.

---

## Pre-requisitos

- AWS Academy com sessao ativa (credenciais temporarias de 4h)
- Terraform >= 1.5 instalado
- kubectl instalado
- Docker instalado (>= 24)
- AWS CLI v2 configurado
- Python 3 instalado (usado pelos scripts de automacao)
- GitHub CLI (gh) instalado (opcional)
- Conta GitHub com repositorio criado

---

## Scripts de Automacao

O projeto inclui 5 scripts em `scripts/` que automatizam todo o setup:

| Script | Funcao |
|--------|--------|
| `setup-full.sh` | **Master** - orquestra todos os 8 passos do setup |
| `generate-secrets.sh` | Gera os 8 `secret.yaml` a partir do `terraform output` + credenciais AWS |
| `apply-secrets.sh` | Aplica todos os secrets no cluster Kubernetes |
| `generate-api-key.sh` | Gera a `SERVICE_API_KEY` via auth-service e atualiza o evaluation-service |
| `update-aws-credentials.sh` | Renova credenciais AWS nos secrets (a cada 4h) |

> **Nota:** Todos os scripts suportam credenciais AWS tanto via variáveis de ambiente (`export`) quanto via `aws configure`.

---

## FASE 1: Infraestrutura com Terraform

### Step 1.1 - Configurar credenciais AWS

**Opcao A — Variaveis de ambiente (recomendado para sessoes temporarias):**
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
# Para o Session Token:
aws configure set aws_session_token "<seu-session-token>"
```

Verificar acesso:
```bash
aws sts get-caller-identity
```

### Step 1.2 - Criar S3 backend (apenas na primeira vez)

O bucket S3 e tabela DynamoDB para o backend remoto do Terraform devem ser criados manualmente (uma unica vez):

```bash
aws s3 mb s3://togglemaster-terraform-state --region us-east-1

aws dynamodb create-table \
  --table-name togglemaster-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 1.3 - Configurar variaveis Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Editar `terraform.tfvars`:
```hcl
aws_region   = "us-east-1"
project_name = "togglemaster"
lab_role_arn = "arn:aws:iam::<ACCOUNT_ID>:role/LabRole"
db_password  = "<SUA_SENHA_SEGURA>"
```

> **IMPORTANTE:** A `db_password` definida aqui sera usada pelo script `generate-secrets.sh` para gerar automaticamente os secrets do Kubernetes. Nao use a senha placeholder `<SUA_SENHA_SEGURA>`.

### Step 1.4 - Inicializar e aplicar Terraform

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

**Recursos criados (39 total):**
- 1 VPC + 2 subnets publicas + 2 subnets privadas + IGW + NAT Gateway + Route Tables
- 1 EKS Cluster + 1 Node Group (t3.medium, 2 nodes)
- 3 instancias RDS PostgreSQL (auth-db, flag-db, targeting-db)
- 1 ElastiCache Redis
- 1 tabela DynamoDB (ToggleMasterAnalytics)
- 1 fila SQS (togglemaster-queue)
- 5 repositorios ECR (com tag IMMUTABLE para seguranca)
- Security Groups para EKS, RDS e Redis

> **Tempo estimado:** ~15-20 minutos para o apply completo.

#### Erro encontrado: DynamoDB digest stale
- **Sintoma:** `terraform init` falhava com "state data in S3 does not have the expected content"
- **Causa:** Sessao anterior deixou digest no DynamoDB que nao bate com o state atual no S3
- **Fix:**
```bash
aws dynamodb delete-item \
  --table-name togglemaster-terraform-lock \
  --key '{"LockID":{"S":"togglemaster-terraform-state/infra/terraform.tfstate-md5"}}' \
  --region us-east-1
terraform init -reconfigure
```

---

## FASE 2: Configurar kubectl

### Step 2.1 - Configurar kubectl para o EKS

```bash
aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
kubectl get nodes  # Deve mostrar 2 nodes Ready
```

---

## FASE 3: Setup Automatizado (Recomendado)

Apos o Terraform apply e kubectl configurado, o script master executa todo o setup:

```bash
./scripts/setup-full.sh
```

O script executa **8 passos** automaticamente:

| Step | Descricao | Script usado |
|------|-----------|-------------|
| 0/8 | Verificacoes iniciais (AWS creds, kubectl) | - |
| 1/8 | Gerar secrets a partir do Terraform output | `generate-secrets.sh` |
| 2/8 | Instalar ArgoCD no cluster | - |
| 3/8 | Aplicar secrets no cluster K8s | `apply-secrets.sh` |
| 4/8 | Build e push de imagens Docker no ECR | - |
| 5/8 | Aplicar ArgoCD Applications | - |
| 6/8 | Instalar NGINX Ingress Controller | - |
| 7/8 | Aguardar pods ficarem prontos | - |
| 8/8 | Gerar SERVICE_API_KEY | `generate-api-key.sh` |

> **Tempo estimado:** ~10-15 minutos (a maior parte e build Docker + espera de pods).

Ao final, o script exibe:
- URL do ArgoCD (LoadBalancer)
- Credenciais do ArgoCD (admin / senha)
- Comandos para verificacao

### O que o `generate-secrets.sh` faz automaticamente:

1. Le `terraform output -json` para extrair endpoints (RDS, Redis, SQS)
2. Le `db_password` do `terraform.tfvars`
3. Detecta credenciais AWS (env vars ou `aws configure`)
4. Gera uma `MASTER_KEY` aleatoria via `openssl rand -hex 32`
5. Cria **8 arquivos `secret.yaml`** com `stringData` (sem necessidade de base64 manual):
   - `gitops/auth-service/secret.yaml` (DATABASE_URL, MASTER_KEY, POSTGRES_PASSWORD)
   - `gitops/auth-service/db/secret.yaml` (POSTGRES_HOST, DB, USER, PASSWORD)
   - `gitops/flag-service/secret.yaml` (DATABASE_URL, POSTGRES_PASSWORD)
   - `gitops/flag-service/db/secret.yaml` (POSTGRES_HOST, DB, USER, PASSWORD)
   - `gitops/targeting-service/secret.yaml` (DATABASE_URL, POSTGRES_PASSWORD)
   - `gitops/targeting-service/db/secret.yaml` (POSTGRES_HOST, DB, USER, PASSWORD)
   - `gitops/evaluation-service/secret.yaml` (REDIS_URL, SQS_URL, AWS creds)
   - `gitops/analytics-service/secret.yaml` (SQS_URL, AWS creds)

> **IMPORTANTE:** Os arquivos `secret.yaml` estao no `.gitignore` e **nunca** sao commitados no git. Eles existem apenas localmente e sao aplicados diretamente no cluster.

### O que o `generate-api-key.sh` faz automaticamente:

1. Verifica se auth-service esta Running
2. Abre port-forward para porta 8001
3. Obtem a MASTER_KEY do secret no cluster
4. Gera uma API key via `POST /admin/keys` com header `Authorization: Bearer`
5. Atualiza o `evaluation-service-secret` com a nova chave via `kubectl patch`
6. Reinicia os pods do evaluation-service para aplicar a mudanca

---

## FASE 3 (Alternativa): Setup Manual Passo a Passo

Se preferir executar manualmente ao inves do `setup-full.sh`:

### Step 3.1 - Gerar secrets a partir do Terraform output

```bash
./scripts/generate-secrets.sh
```

### Step 3.2 - Instalar ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

#### Erro encontrado: CRD too long
- **Sintoma:** `kubectl apply` falhava com "metadata.annotations: Too long"
- **Fix:** Usar `--server-side` (ja incluido no comando acima)

### Step 3.3 - Expor ArgoCD e obter senha

```bash
# Expor via LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Obter URL (pode levar 2-3 min para propagar)
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Obter senha admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

### Step 3.4 - Aplicar secrets no cluster

```bash
./scripts/apply-secrets.sh
```

### Step 3.5 - Build e push das imagens Docker

```bash
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

> **IMPORTANTE:** Usar `--platform linux/amd64` se estiver em Mac com Apple Silicon (M1/M2/M3).

> **IMPORTANTE:** As imagens Docker devem ser enviadas ao ECR **antes** de aplicar as ArgoCD Applications, caso contrario os pods ficarao em `ImagePullBackOff`.

### Step 3.6 - Aplicar ArgoCD Applications

```bash
kubectl apply -f argocd/applications.yaml
```

### Step 3.7 - Instalar NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml
```

### Step 3.8 - Verificar pods

```bash
kubectl get pods -n togglemaster
```

Deve mostrar:
- 10 pods Running (2 replicas x 5 servicos)
- 3 DB init jobs Completed (auth, flag, targeting)

### Step 3.9 - Gerar SERVICE_API_KEY (para evaluation-service)

**Via script automatizado (recomendado):**
```bash
./scripts/generate-api-key.sh
```

**Manualmente:**
```bash
# Port-forward para auth-service
kubectl port-forward svc/auth-service 8001:8001 -n togglemaster &

# Obter MASTER_KEY do secret
MASTER_KEY=$(kubectl get secret auth-service-secret -n togglemaster -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

# Gerar chave (ATENCAO ao header e campo corretos)
curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"name": "evaluation-service"}'
```

Copiar o campo `key` da resposta JSON e atualizar o secret:
```bash
API_KEY="<chave-retornada>"
API_KEY_B64=$(echo -n "$API_KEY" | base64)

kubectl patch secret evaluation-service-secret -n togglemaster \
  -p "{\"data\":{\"SERVICE_API_KEY\":\"$API_KEY_B64\"}}"

# Reiniciar evaluation-service para aplicar
kubectl rollout restart deployment/evaluation-service -n togglemaster
```

> **ATENCAO:** O header correto e `Authorization: Bearer $MASTER_KEY` (nao `X-Master-Key`). O campo no JSON e `name` (nao `description`).

---

## FASE 4: CI/CD Pipeline

### Step 4.1 - Configurar GitHub Secrets

No repositorio GitHub, ir em Settings > Secrets and variables > Actions e adicionar:

| Secret | Valor |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | Access Key da sessao AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | Secret Key da sessao |
| `AWS_SESSION_TOKEN` | Session Token da sessao |
| `ECR_REGISTRY` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com` |

> **IMPORTANTE:** Atualizar esses secrets a cada nova sessao AWS Academy (4h).

### Step 4.2 - Testar o pipeline

Fazer uma alteracao em qualquer microsservico e push para main:

```bash
# Exemplo: alterar algo no auth-service
echo "// trigger pipeline" >> microservices/auth-service/main.go
git add microservices/auth-service/main.go
git commit -m "feat(auth): trigger CI/CD pipeline test"
git push
```

O pipeline executa sequencialmente:
1. **Build & Unit Test** - Compila e testa
2. **Linter / Static Analysis** - golangci-lint (Go) ou flake8 (Python)
3. **Security Scan (SAST & SCA)** - Trivy SCA (bloqueante, `exit-code: 1`) + gosec/bandit SAST
4. **Docker Build & Push to ECR** - Build + Trivy container scan + Push (tag: `<commit-sha>`)
5. **Update GitOps Manifests** - Atualiza image tag em `gitops/<service>/deployment.yaml` + commit automatico

O ArgoCD detecta a mudanca no manifesto e faz rolling update automatico.

---

## FASE 5: Manutencao

### Renovar credenciais AWS (a cada 4h)

Quando a sessao AWS Academy expira:

1. Obter novas credenciais do AWS Academy
2. Configurar via env vars ou `aws configure`
3. Executar:
```bash
./scripts/update-aws-credentials.sh
```

O script atualiza automaticamente os secrets do `evaluation-service` e `analytics-service` (que usam SQS/DynamoDB) e reinicia os pods.

4. Atualizar tambem os GitHub Secrets (para CI/CD):
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_SESSION_TOKEN`

---

## Erros Encontrados e Fixes

### Erro 1: `go.sum` faltando
- **Sintoma:** Build falhou com "missing go.sum entry"
- **Causa:** Os servicos Go nao tinham `go.sum` commitado no repo
- **Fix:**
```bash
docker run --rm -v $(pwd)/microservices/auth-service:/app -w /app golang:1.21 go mod tidy
docker run --rm -v $(pwd)/microservices/evaluation-service:/app -w /app golang:1.21 go mod tidy
git add microservices/*/go.sum && git commit -m "fix: add go.sum files" && git push
```

### Erro 2: golangci-lint errcheck
- **Sintoma:** Lint falhou com "Error return value of json.NewEncoder(w).Encode is not checked"
- **Causa:** Retorno de `json.Encode()` nao verificado em handlers
- **Fix:** Envolver todas as chamadas com error check:
```go
if err := json.NewEncoder(w).Encode(data); err != nil {
    log.Printf("Erro ao codificar resposta: %v", err)
}
```
Tambem: substituir `io/ioutil` (deprecated) por `io`, e verificar `Redis.Set().Err()`

### Erro 3: Trivy bloqueando pipeline
- **Sintoma:** Security Scan falhava com CVEs CRITICAL em dependencias upstream
- **Causa:** CVEs em libs transitivas fora do nosso controle (ex: golang.org/x/net)
- **Decisao:** O Trivy filesystem scan opera com `exit-code: '1'` (bloqueante) para garantir DevSecOps rigoroso. Em caso de falso positivo em dependencias transitivas, avaliar atualizacao da lib ou ajustar o workflow temporariamente.

### Erro 4: gosec incompativel com Go 1.21
- **Sintoma:** gosec@latest falhava com "requires Go >= 1.25"
- **Causa:** Versao latest do gosec precisa de Go mais recente que o usado no CI
- **Fix:** Pinar versao: `go install github.com/securego/gosec/v2/cmd/gosec@v2.20.0` + `continue-on-error: true`

### Erro 5: GITHUB_TOKEN sem permissao de push
- **Sintoma:** Job "Update GitOps Manifests" falhava no step "Commit and push"
- **Causa:** O GITHUB_TOKEN padrao nao tem permissao de write no conteudo do repo
- **Fix:** Adicionar `permissions: contents: write` no job `update-gitops` (nao no workflow global, para seguir principio de menor privilegio):
```yaml
update-gitops:
  name: Update GitOps Manifests
  needs: docker-build-push
  runs-on: ubuntu-latest
  permissions:
    contents: write
  steps:
    ...
```

### Erro 6: Secrets com credenciais expostas no git
- **Sintoma:** Secrets com senhas e credenciais AWS estavam inline nos `deployment.yaml` e commitados no repositorio
- **Causa:** Manifestos originais incluiam os Secrets diretamente no mesmo arquivo do Deployment
- **Fix:**
  1. Extrair Secrets dos `deployment.yaml` para arquivos `secret.yaml` separados
  2. Adicionar `gitops/**/secret.yaml` ao `.gitignore`
  3. Criar `secret.yaml.example` com placeholders para cada servico
  4. Criar scripts de automacao (`generate-secrets.sh`, `apply-secrets.sh`) para gerar e aplicar secrets a partir do Terraform output
  5. Remover secrets do tracking do git: `git rm --cached gitops/*/secret.yaml gitops/*/db/secret.yaml`

### Erro 7: ImagePullBackOff por ordem de execucao
- **Sintoma:** Pods ficavam em `ImagePullBackOff` apos aplicar ArgoCD Applications
- **Causa:** As imagens Docker ainda nao haviam sido enviadas ao ECR quando o ArgoCD tentou fazer deploy
- **Fix:** Garantir que o build/push Docker aconteca **antes** de aplicar as ArgoCD Applications. O `setup-full.sh` ja segue esta ordem correta.

### Erro 8: `sed` incompativel com macOS
- **Sintoma:** Script `generate-secrets.sh` nao conseguia extrair `db_password` do `terraform.tfvars` no macOS
- **Causa:** `sed` do macOS (BSD) nao suporta `\s` (whitespace regex). Apenas o GNU sed suporta.
- **Fix:** Substituir `sed` por `python3`:
```bash
# Antes (ERRADO no macOS):
DB_PASSWORD=$(grep 'db_password' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/')

# Depois (funciona em macOS e Linux):
DB_PASSWORD=$(grep 'db_password' terraform.tfvars | python3 -c "import sys; print(sys.stdin.read().split('\"')[1])")
```

### Erro 9: Header errado para gerar API Key
- **Sintoma:** `curl` para `/admin/keys` retornava "Acesso nao autorizado"
- **Causa:** Header incorreto `X-Master-Key` e campo incorreto `description`
- **Fix:** O auth-service espera:
  - Header: `Authorization: Bearer $MASTER_KEY`
  - Campo JSON: `name` (nao `description`)
```bash
curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"name": "evaluation-service"}'
```

---

## Gestao de Secrets

### Arquitetura de Secrets

Os secrets Kubernetes sao gerenciados **fora do git** por questoes de seguranca:

```
terraform output (endpoints)  +  terraform.tfvars (db_password)  +  AWS credentials
                           \                |                      /
                            +---------------+--------------------+
                                            |
                                  generate-secrets.sh
                                            |
                                  8 arquivos secret.yaml
                                  (gitignored, locais)
                                            |
                                   apply-secrets.sh
                                            |
                                   kubectl apply -f
                                            |
                                  Kubernetes Secrets
                                  (no cluster EKS)
```

### Formato `stringData` vs `data`

Os secrets usam `stringData` (valores em texto puro) ao inves de `data` (base64). O Kubernetes converte automaticamente para base64 ao aplicar. Isso simplifica a geracao automatica:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: auth-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_PASSWORD: "minha-senha-real"    # texto puro, sem base64
  MASTER_KEY: "abc123def456..."
  DATABASE_URL: "postgres://tm_user:minha-senha-real@host:5432/auth_db"
```

### Templates de Referencia

Cada servico tem um `secret.yaml.example` com placeholders para referencia:
- `gitops/auth-service/secret.yaml.example`
- `gitops/flag-service/secret.yaml.example`
- `gitops/targeting-service/secret.yaml.example`
- `gitops/evaluation-service/secret.yaml.example`
- `gitops/analytics-service/secret.yaml.example`

---

## Resumo da Sequencia de Execucao

### Via script automatizado (recomendado):
```
1. Configurar credenciais AWS (env vars ou aws configure)
2. terraform init && terraform apply (~15-20 min)
3. aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
4. ./scripts/setup-full.sh (~10-15 min)
   ├── [1/8] generate-secrets.sh (le terraform output + creds AWS)
   ├── [2/8] Instala ArgoCD
   ├── [3/8] apply-secrets.sh (aplica 8 secrets no cluster)
   ├── [4/8] Build + Push 5 imagens Docker para ECR
   ├── [5/8] Aplica ArgoCD Applications
   ├── [6/8] Instala NGINX Ingress Controller
   ├── [7/8] Aguarda pods ficarem prontos
   └── [8/8] generate-api-key.sh (gera SERVICE_API_KEY)
5. Configurar GitHub Secrets (AWS creds + ECR_REGISTRY)
6. Testar CI/CD com push de codigo
7. Verificar ArgoCD sync automatico
```

### Via execucao manual:
```
1. Configurar credenciais AWS (env vars ou aws configure)
2. terraform init && terraform apply (~15-20 min)
3. aws eks update-kubeconfig
4. ./scripts/generate-secrets.sh
5. Instalar ArgoCD (kubectl create ns + apply --server-side)
6. ./scripts/apply-secrets.sh
7. Build + Push 5 imagens Docker para ECR
8. kubectl apply -f argocd/applications.yaml
9. Instalar NGINX Ingress Controller
10. Verificar todos os pods Running
11. ./scripts/generate-api-key.sh
12. Configurar GitHub Secrets
13. Testar CI/CD com push de codigo
```
