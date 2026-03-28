#!/bin/bash
###############################################################################
# setup-full.sh
#
# Script master que executa o setup completo do ambiente ToggleMaster.
# Orquestra todos os outros scripts na ordem correta.
#
# Uso:
#   # Primeiro: exportar credenciais AWS e rodar terraform apply
#   # Depois:
#   ./scripts/setup-full.sh
#
# Pre-requisitos:
#   - terraform apply ja executado com sucesso
#   - Credenciais AWS (via env vars OU aws configure)
#   - db_password configurada no terraform.tfvars
#   - kubectl configurado para o cluster EKS (ou o script configura automaticamente)
#   - Docker instalado (para build das imagens)
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  ToggleMaster - Setup Completo"
echo "============================================"
echo ""

###############################################################################
# Verificacoes iniciais
###############################################################################
echo ">>> [0/10] Verificacoes iniciais..."

# AWS credentials (suporta env vars OU aws configure)
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
fi
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
fi
if [ -z "$AWS_SESSION_TOKEN" ]; then
  AWS_SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "ERRO: Credenciais AWS nao encontradas (nem em env vars, nem em aws configure)."
  echo "Execute antes:"
  echo '  export AWS_ACCESS_KEY_ID="..."'
  echo '  export AWS_SECRET_ACCESS_KEY="..."'
  echo '  export AWS_SESSION_TOKEN="..."'
  echo "Ou configure via: aws configure"
  exit 1
fi
echo "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:12}..."

# kubectl
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo ">>> kubectl nao conectado. Configurando..."
  aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
fi

kubectl get nodes
echo ""

###############################################################################
# Step 1: Gerar secrets
###############################################################################
echo ">>> [1/10] Gerando secrets a partir do Terraform..."
"$SCRIPT_DIR/generate-secrets.sh"

###############################################################################
# Step 2: Instalar ArgoCD
###############################################################################
echo ">>> [2/10] Instalando ArgoCD..."

if kubectl get namespace argocd > /dev/null 2>&1; then
  echo "  ArgoCD namespace ja existe, pulando instalacao."
else
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
fi

echo "  Aguardando ArgoCD ficar pronto..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Expor via LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}' 2>/dev/null || true

echo "  [OK] ArgoCD instalado"
echo ""

###############################################################################
# Step 3: Aplicar secrets no cluster
###############################################################################
echo ">>> [3/10] Aplicando secrets no cluster..."
"$SCRIPT_DIR/apply-secrets.sh"

###############################################################################
# Step 4: Build e push de imagens Docker no ECR
###############################################################################
echo ">>> [4/10] Build e push de imagens Docker..."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
GITHUB_REPO_URL=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||')
GITHUB_USER=$(echo "$GITHUB_REPO_URL" | sed 's|https://github.com/||' | cut -d/ -f1)

echo "  ECR Registry: $ECR_REGISTRY"
echo "  GitHub User:  $GITHUB_USER"
echo "  GitHub Repo:  $GITHUB_REPO_URL"

# Substituir placeholders nos manifestos GitOps (ECR image URLs)
echo "  Atualizando placeholders nos manifestos..."
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  DEPLOY_FILE="$PROJECT_DIR/gitops/$svc/deployment.yaml"
  if grep -q '<AWS_ACCOUNT_ID>' "$DEPLOY_FILE" 2>/dev/null; then
    sed -i.bak "s|<AWS_ACCOUNT_ID>|$ACCOUNT_ID|g" "$DEPLOY_FILE" && rm -f "$DEPLOY_FILE.bak"
    echo "    [OK] $svc deployment.yaml atualizado"
  fi
done

# Substituir placeholder no ArgoCD (GitHub repo URL)
ARGOCD_FILE="$PROJECT_DIR/argocd/applications.yaml"
if grep -q '<GITHUB_USER>' "$ARGOCD_FILE" 2>/dev/null; then
  sed -i.bak "s|<GITHUB_USER>|$GITHUB_USER|g" "$ARGOCD_FILE" && rm -f "$ARGOCD_FILE.bak"
  echo "    [OK] argocd/applications.yaml atualizado"
fi

# Commit e push dos manifestos atualizados para que ArgoCD sincronize corretamente
echo "  Commitando manifestos atualizados no git..."
git -C "$PROJECT_DIR" add gitops/*/deployment.yaml argocd/applications.yaml 2>/dev/null
if ! git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
  git -C "$PROJECT_DIR" commit -m "Update manifests with AWS account $ACCOUNT_ID and GitHub user $GITHUB_USER" --quiet
  git -C "$PROJECT_DIR" push --quiet 2>/dev/null || echo "    [AVISO] git push falhou — faca push manualmente antes do ArgoCD sync"
  echo "    [OK] Manifestos commitados e enviados ao repositorio"
else
  echo "    Manifestos ja estavam atualizados no git"
fi
echo ""

# Login no ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Verificar se imagens ja existem no ECR
SKIP_BUILD=true
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  IMAGE_COUNT=$(aws ecr list-images --repository-name "$svc" --region us-east-1 --query 'length(imageIds)' --output text 2>/dev/null || echo "0")
  if [ "$IMAGE_COUNT" = "0" ] || [ "$IMAGE_COUNT" = "None" ]; then
    SKIP_BUILD=false
    break
  fi
done

if [ "$SKIP_BUILD" = "true" ]; then
  echo "  Imagens ja existem no ECR, pulando build."
else
  echo "  Construindo e enviando imagens (isso pode levar 5-10 minutos)..."
  for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
    echo "  >>> Building $svc..."
    docker build --platform linux/amd64 -t "$ECR_REGISTRY/$svc:latest" "$PROJECT_DIR/microservices/$svc"
    docker push "$ECR_REGISTRY/$svc:latest"
    echo "  [OK] $svc"
  done
fi
echo ""

###############################################################################
# Step 5: Aplicar ArgoCD Applications
###############################################################################
echo ">>> [5/10] Aplicando ArgoCD Applications..."
kubectl apply -f "$PROJECT_DIR/argocd/applications.yaml"
echo "  [OK] Applications criadas"
echo ""

###############################################################################
# Step 6: Instalar NGINX Ingress
###############################################################################
echo ">>> [6/10] Instalando NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/aws/deploy.yaml 2>/dev/null || true
echo "  [OK] NGINX Ingress instalado"
echo ""

###############################################################################
# Step 7: Aguardar pods
###############################################################################
echo ">>> [7/10] Aguardando pods do ToggleMaster ficarem prontos..."
echo "  (isso pode levar 2-5 minutos)"

# Aguardar deployments
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo -n "  Aguardando $svc... "
  kubectl rollout status deployment/$svc -n togglemaster --timeout=180s 2>/dev/null || echo "(pode demorar mais)"
done

echo ""
kubectl get pods -n togglemaster
echo ""

###############################################################################
# Step 8: Gerar API Key
###############################################################################
echo ">>> [8/10] Gerando SERVICE_API_KEY..."
"$SCRIPT_DIR/generate-api-key.sh"

###############################################################################
# Step 9: Garantir namespace monitoring e secrets manuais
###############################################################################
echo ">>> [9/10] Garantindo namespace monitoring e secrets..."

kubectl get namespace monitoring > /dev/null 2>&1 || kubectl create namespace monitoring
echo "  [OK] namespace monitoring"

NR_SECRET_FILE="$PROJECT_DIR/gitops/monitoring/newrelic-secret.yaml"
if [ -f "$NR_SECRET_FILE" ]; then
  kubectl apply -f "$NR_SECRET_FILE"
  echo "  [OK] New Relic secret aplicado"
else
  echo "  [AVISO] $NR_SECRET_FILE nao encontrado — APM New Relic nao configurado."
  echo "    cp gitops/monitoring/newrelic-secret.yaml.example gitops/monitoring/newrelic-secret.yaml"
fi

AM_SECRET_FILE="$PROJECT_DIR/gitops/monitoring/alerting/alertmanager-secret.yaml"
if [ -f "$AM_SECRET_FILE" ]; then
  kubectl apply -f "$AM_SECRET_FILE"
  echo "  [OK] Alertmanager secret aplicado"
else
  echo "  [AVISO] $AM_SECRET_FILE nao encontrado — alerting nao configurado."
  echo "    cp gitops/monitoring/alerting/alertmanager-config.yaml gitops/monitoring/alerting/alertmanager-secret.yaml"
  echo "    # Preencha PAGERDUTY_INTEGRATION_KEY, DISCORD_WEBHOOK_URL e GITHUB_PAT_TOKEN"
fi
echo ""

###############################################################################
# Step 10: Instalar Monitoring Stack (Fase 4)
###############################################################################
echo ">>> [10/10] Instalando Monitoring Stack (Prometheus + Loki + Grafana + OTel)..."
"$SCRIPT_DIR/install-monitoring.sh"
echo ""

###############################################################################
# Resumo final
###############################################################################
echo ""
echo "============================================"
echo "  SETUP COMPLETO!"
echo "============================================"
echo ""

ARGOCD_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pendente")
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "N/A")

echo "ArgoCD:"
echo "  URL:   https://$ARGOCD_URL"
echo "  User:  admin"
echo "  Pass:  $ARGOCD_PASS"
echo ""
echo "Grafana (Monitoring):"
GRAFANA_URL=$(kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pendente")
echo "  URL:   http://$GRAFANA_URL"
echo "  User:  admin"
echo "  Pass:  togglemaster2024"
echo ""
echo "OTel Collector:"
echo "  gRPC: otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317"
echo "  HTTP: otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4318"
echo ""
echo "Verificar pods:"
echo "  kubectl get pods -n togglemaster"
echo "  kubectl get pods -n monitoring"
echo ""
echo "Testar health:"
echo "  kubectl port-forward svc/auth-service 8001:8001 -n togglemaster &"
echo "  curl http://localhost:8001/health"
echo ""
echo "Atualizar credenciais AWS (a cada 4h):"
echo "  ./scripts/update-aws-credentials.sh"
echo ""
