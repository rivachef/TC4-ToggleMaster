#!/bin/bash
###############################################################################
# update-aws-credentials.sh
#
# Atualiza as credenciais AWS nos secrets do evaluation-service e
# analytics-service. Necessario a cada nova sessao AWS Academy (4h).
#
# Uso:
#   # Opcao A: via env vars
#   export AWS_ACCESS_KEY_ID="..."
#   export AWS_SECRET_ACCESS_KEY="..."
#   export AWS_SESSION_TOKEN="..."
#   ./scripts/update-aws-credentials.sh
#
#   # Opcao B: via aws configure (o script detecta automaticamente)
#   aws configure
#   ./scripts/update-aws-credentials.sh
###############################################################################
set -e

echo "============================================"
echo "  ToggleMaster - Atualizar Credenciais AWS"
echo "============================================"
echo ""

# Verificar credenciais (suporta env vars OU aws configure)
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

echo ">>> AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:12}..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GITOPS_DIR="$PROJECT_DIR/gitops"

# Atualizar evaluation-service secret
echo ">>> Atualizando evaluation-service-secret..."
# Preservar valores existentes (REDIS_URL, SERVICE_API_KEY, SQS_URL)
REDIS_URL=$(kubectl get secret evaluation-service-secret -n togglemaster -o jsonpath='{.data.REDIS_URL}' | base64 -d)
SERVICE_API_KEY=$(kubectl get secret evaluation-service-secret -n togglemaster -o jsonpath='{.data.SERVICE_API_KEY}' | base64 -d)
AWS_SQS_URL=$(kubectl get secret evaluation-service-secret -n togglemaster -o jsonpath='{.data.AWS_SQS_URL}' | base64 -d)

cat > /tmp/eval-secret-update.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  REDIS_URL: "$REDIS_URL"
  SERVICE_API_KEY: "$SERVICE_API_KEY"
  AWS_SQS_URL: "$AWS_SQS_URL"
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"
  AWS_SESSION_TOKEN: "$AWS_SESSION_TOKEN"
EOF
kubectl apply -f /tmp/eval-secret-update.yaml
rm -f /tmp/eval-secret-update.yaml
echo "  [OK] evaluation-service-secret"

# Atualizar analytics-service secret
echo ">>> Atualizando analytics-service-secret..."
AWS_SQS_URL_ANALYTICS=$(kubectl get secret analytics-service-secret -n togglemaster -o jsonpath='{.data.AWS_SQS_URL}' | base64 -d)

cat > /tmp/analytics-secret-update.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: analytics-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  AWS_SQS_URL: "$AWS_SQS_URL_ANALYTICS"
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"
  AWS_SESSION_TOKEN: "$AWS_SESSION_TOKEN"
EOF
kubectl apply -f /tmp/analytics-secret-update.yaml
rm -f /tmp/analytics-secret-update.yaml
echo "  [OK] analytics-service-secret"

# Restart dos pods para pegar os novos credentials
echo ""
echo ">>> Reiniciando pods para aplicar novas credenciais..."
kubectl rollout restart deployment/evaluation-service -n togglemaster
kubectl rollout restart deployment/analytics-service -n togglemaster

echo ""
echo "============================================"
echo "  Credenciais AWS atualizadas!"
echo "============================================"
echo ""
echo "Aguarde os pods reiniciarem:"
echo "  kubectl get pods -n togglemaster -w"
echo ""
