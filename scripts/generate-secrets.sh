#!/bin/bash
###############################################################################
# generate-secrets.sh
#
# Gera automaticamente todos os secret.yaml do Kubernetes a partir dos
# outputs do Terraform + credenciais AWS da sessao atual.
#
# Uso:
#   cd TC3-ToggleMaster
#   ./scripts/generate-secrets.sh
#
# Pre-requisitos:
#   - terraform apply ja executado (para obter outputs)
#   - Credenciais AWS (via env vars OU aws configure)
#   - db_password definida no terraform.tfvars
###############################################################################
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
GITOPS_DIR="$PROJECT_DIR/gitops"

echo "============================================"
echo "  ToggleMaster - Gerador de Secrets"
echo "============================================"
echo ""

###############################################################################
# 1) Obter outputs do Terraform
###############################################################################
echo ">>> Lendo outputs do Terraform..."
cd "$TERRAFORM_DIR"

if ! terraform output -json > /dev/null 2>&1; then
  echo "ERRO: Nao foi possivel ler terraform output."
  echo "Verifique se 'terraform apply' foi executado com sucesso."
  exit 1
fi

TF_OUTPUT=$(terraform output -json)

# Extrair endpoints (RDS endpoint vem como "host:5432", extraimos so o host)
AUTH_DB_ENDPOINT=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['auth_db_endpoint']['value'].split(':')[0])")
FLAG_DB_ENDPOINT=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['flag_db_endpoint']['value'].split(':')[0])")
TARGETING_DB_ENDPOINT=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['targeting_db_endpoint']['value'].split(':')[0])")
REDIS_ENDPOINT=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['redis_endpoint']['value'])")
SQS_QUEUE_URL=$(echo "$TF_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sqs_queue_url']['value'])")

echo "  auth_db:    $AUTH_DB_ENDPOINT"
echo "  flag_db:    $FLAG_DB_ENDPOINT"
echo "  targeting:  $TARGETING_DB_ENDPOINT"
echo "  redis:      $REDIS_ENDPOINT"
echo "  sqs:        $SQS_QUEUE_URL"
echo ""

###############################################################################
# 2) Obter db_password do terraform.tfvars
###############################################################################
echo ">>> Lendo db_password do terraform.tfvars..."

if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
  echo "ERRO: terraform.tfvars nao encontrado."
  echo "Crie com: cp terraform.tfvars.example terraform.tfvars"
  exit 1
fi

DB_PASSWORD=$(grep 'db_password' "$TERRAFORM_DIR/terraform.tfvars" | python3 -c "import sys; print(sys.stdin.read().split('\"')[1])")

if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "<SUA_SENHA_SEGURA>" ]; then
  echo "ERRO: db_password nao definida no terraform.tfvars"
  exit 1
fi
echo "  db_password: ****${DB_PASSWORD: -4}"
echo ""

###############################################################################
# 3) Verificar credenciais AWS (suporta env vars OU aws configure)
###############################################################################
echo ">>> Verificando credenciais AWS..."

# Tentar env vars primeiro, senao ler de aws configure
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
echo ""

###############################################################################
# 4) Definir MASTER_KEY (gerar se nao existir)
###############################################################################
MASTER_KEY="${MASTER_KEY:-$(openssl rand -hex 32)}"
echo ">>> MASTER_KEY: ${MASTER_KEY:0:8}..."
echo ""

###############################################################################
# 5) Gerar os 8 secret.yaml
###############################################################################
echo ">>> Gerando secrets em $GITOPS_DIR ..."
echo ""

# --- auth-service/secret.yaml ---
cat > "$GITOPS_DIR/auth-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_PASSWORD: "$DB_PASSWORD"
  MASTER_KEY: "$MASTER_KEY"
  DATABASE_URL: "postgres://tm_user:${DB_PASSWORD}@${AUTH_DB_ENDPOINT}:5432/auth_db"
EOF
echo "  [OK] gitops/auth-service/secret.yaml"

# --- auth-service/db/secret.yaml ---
cat > "$GITOPS_DIR/auth-service/db/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-db-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_HOST: "$AUTH_DB_ENDPOINT"
  POSTGRES_DB: "auth_db"
  POSTGRES_USER: "tm_user"
  POSTGRES_PASSWORD: "$DB_PASSWORD"
EOF
echo "  [OK] gitops/auth-service/db/secret.yaml"

# --- flag-service/secret.yaml ---
cat > "$GITOPS_DIR/flag-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: flag-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_PASSWORD: "$DB_PASSWORD"
  DATABASE_URL: "postgres://tm_user:${DB_PASSWORD}@${FLAG_DB_ENDPOINT}:5432/flag_db"
EOF
echo "  [OK] gitops/flag-service/secret.yaml"

# --- flag-service/db/secret.yaml ---
cat > "$GITOPS_DIR/flag-service/db/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: flag-db-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_HOST: "$FLAG_DB_ENDPOINT"
  POSTGRES_DB: "flag_db"
  POSTGRES_USER: "tm_user"
  POSTGRES_PASSWORD: "$DB_PASSWORD"
EOF
echo "  [OK] gitops/flag-service/db/secret.yaml"

# --- targeting-service/secret.yaml ---
cat > "$GITOPS_DIR/targeting-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: targeting-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_PASSWORD: "$DB_PASSWORD"
  DATABASE_URL: "postgres://tm_user:${DB_PASSWORD}@${TARGETING_DB_ENDPOINT}:5432/targeting_db"
EOF
echo "  [OK] gitops/targeting-service/secret.yaml"

# --- targeting-service/db/secret.yaml ---
cat > "$GITOPS_DIR/targeting-service/db/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: targeting-db-secret
  namespace: togglemaster
type: Opaque
stringData:
  POSTGRES_HOST: "$TARGETING_DB_ENDPOINT"
  POSTGRES_DB: "targeting_db"
  POSTGRES_USER: "tm_user"
  POSTGRES_PASSWORD: "$DB_PASSWORD"
EOF
echo "  [OK] gitops/targeting-service/db/secret.yaml"

# --- evaluation-service/secret.yaml ---
cat > "$GITOPS_DIR/evaluation-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  REDIS_URL: "redis://${REDIS_ENDPOINT}:6379"
  SERVICE_API_KEY: "PLACEHOLDER_GERAR_DEPOIS"
  AWS_SQS_URL: "$SQS_QUEUE_URL"
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"
  AWS_SESSION_TOKEN: "$AWS_SESSION_TOKEN"
EOF
echo "  [OK] gitops/evaluation-service/secret.yaml"

# --- analytics-service/secret.yaml ---
cat > "$GITOPS_DIR/analytics-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: analytics-service-secret
  namespace: togglemaster
type: Opaque
stringData:
  AWS_SQS_URL: "$SQS_QUEUE_URL"
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"
  AWS_SESSION_TOKEN: "$AWS_SESSION_TOKEN"
EOF
echo "  [OK] gitops/analytics-service/secret.yaml"

echo ""
echo "============================================"
echo "  8 secrets gerados com sucesso!"
echo "============================================"
echo ""
echo "Proximo passo - aplicar no cluster:"
echo ""
echo "  ./scripts/apply-secrets.sh"
echo ""
echo "NOTA: O SERVICE_API_KEY do evaluation-service sera"
echo "gerado automaticamente apos o auth-service subir."
echo "Execute: ./scripts/generate-api-key.sh"
echo ""
