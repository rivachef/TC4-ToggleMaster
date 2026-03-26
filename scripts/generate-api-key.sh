#!/bin/bash
###############################################################################
# generate-api-key.sh
#
# Gera uma SERVICE_API_KEY via auth-service e atualiza automaticamente
# o secret do evaluation-service.
#
# Uso (apos os pods estarem Running):
#   ./scripts/generate-api-key.sh
###############################################################################
set -e

echo "============================================"
echo "  ToggleMaster - Gerar SERVICE_API_KEY"
echo "============================================"
echo ""

# Verificar se auth-service esta rodando
echo ">>> Verificando se auth-service esta Running..."
AUTH_STATUS=$(kubectl get pods -n togglemaster -l app=auth-service -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

if [ "$AUTH_STATUS" != "Running" ]; then
  echo "ERRO: auth-service nao esta Running (status: $AUTH_STATUS)"
  echo "Aguarde os pods subirem: kubectl get pods -n togglemaster -w"
  exit 1
fi
echo "  [OK] auth-service esta Running"
echo ""

# Verificar se porta 8001 ja esta em uso
if lsof -i :8001 > /dev/null 2>&1; then
  echo "  AVISO: Porta 8001 ja em uso. Tentando liberar..."
  kill $(lsof -t -i :8001) 2>/dev/null || true
  sleep 2
fi

# Port-forward em background
echo ">>> Abrindo port-forward para auth-service..."
kubectl port-forward svc/auth-service 8001:8001 -n togglemaster &
PF_PID=$!
sleep 3

# Cleanup ao sair
cleanup() {
  kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Obter MASTER_KEY
echo ">>> Obtendo MASTER_KEY do secret..."
MASTER_KEY=$(kubectl get secret auth-service-secret -n togglemaster \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

if [ -z "$MASTER_KEY" ]; then
  echo "ERRO: MASTER_KEY nao encontrada no secret auth-service-secret"
  exit 1
fi
echo "  [OK] MASTER_KEY: ${MASTER_KEY:0:8}..."
echo ""

# Gerar API key
echo ">>> Gerando API key via auth-service..."
RESPONSE=$(curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"name": "evaluation-service"}')

API_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")

if [ -z "$API_KEY" ]; then
  echo "ERRO: Nao foi possivel gerar a API key."
  echo "Resposta do auth-service: $RESPONSE"
  exit 1
fi
echo "  [OK] API Key gerada: ${API_KEY:0:15}..."
echo ""

# Atualizar o secret do evaluation-service via kubectl patch
echo ">>> Atualizando evaluation-service-secret com a nova API key..."
API_KEY_B64=$(echo -n "$API_KEY" | base64)

kubectl patch secret evaluation-service-secret -n togglemaster \
  -p "{\"data\":{\"SERVICE_API_KEY\":\"$API_KEY_B64\"}}"

echo "  [OK] evaluation-service-secret atualizado"
echo ""

# Restart dos pods do evaluation-service para pegar o novo secret
echo ">>> Reiniciando pods do evaluation-service..."
kubectl rollout restart deployment/evaluation-service -n togglemaster
kubectl rollout status deployment/evaluation-service -n togglemaster --timeout=120s
echo ""

echo "============================================"
echo "  SERVICE_API_KEY configurada com sucesso!"
echo "============================================"
echo ""
echo "API Key: $API_KEY"
echo ""
echo "Todos os servicos devem estar operacionais agora."
echo "Verifique: kubectl get pods -n togglemaster"
echo ""
