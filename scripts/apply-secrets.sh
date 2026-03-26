#!/bin/bash
###############################################################################
# apply-secrets.sh
#
# Aplica todos os secrets gerados no cluster Kubernetes.
# Executar apos generate-secrets.sh
#
# Uso:
#   ./scripts/apply-secrets.sh
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GITOPS_DIR="$PROJECT_DIR/gitops"

echo "============================================"
echo "  ToggleMaster - Aplicar Secrets no Cluster"
echo "============================================"
echo ""

# Verificar conexao com cluster
echo ">>> Verificando conexao com o cluster..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "ERRO: Nao conectado ao cluster. Execute:"
  echo "  aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1"
  exit 1
fi
echo "  [OK] Conectado ao cluster"
echo ""

# Criar namespace se nao existir
echo ">>> Garantindo namespace togglemaster..."
kubectl apply -f "$GITOPS_DIR/namespace.yaml"
echo ""

# Aplicar os 8 secrets
echo ">>> Aplicando secrets..."

SECRETS=(
  "auth-service/secret.yaml"
  "auth-service/db/secret.yaml"
  "flag-service/secret.yaml"
  "flag-service/db/secret.yaml"
  "targeting-service/secret.yaml"
  "targeting-service/db/secret.yaml"
  "evaluation-service/secret.yaml"
  "analytics-service/secret.yaml"
)

for secret in "${SECRETS[@]}"; do
  FILE="$GITOPS_DIR/$secret"
  if [ -f "$FILE" ]; then
    kubectl apply -f "$FILE"
    echo "  [OK] $secret"
  else
    echo "  [SKIP] $secret (arquivo nao encontrado - execute generate-secrets.sh primeiro)"
  fi
done

echo ""
echo ">>> Verificando secrets criados..."
echo ""
kubectl get secrets -n togglemaster --no-headers | grep -v 'default-token' | grep -v 'sh.helm'
echo ""

echo "============================================"
echo "  Secrets aplicados com sucesso!"
echo "============================================"
echo ""
echo "Proximo passo:"
echo "  kubectl apply -f argocd/applications.yaml"
echo ""
