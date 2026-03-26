#!/bin/bash
set -e

########################################################################
# destroy-all.sh - Script de destruição completa da infraestrutura
#
# Resolve o problema de LoadBalancers criados pelo Kubernetes (NGINX
# Ingress Controller) que bloqueiam o terraform destroy por causa de
# ENIs (Elastic Network Interfaces) associadas à VPC.
#
# Ordem de execução:
#   1. Deleta recursos Kubernetes (Services tipo LoadBalancer)
#   2. Aguarda LoadBalancers serem removidos da AWS
#   3. Limpa ENIs órfãs na VPC
#   4. Roda terraform destroy
#
# Uso: ./scripts/destroy-all.sh
########################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
CLUSTER_NAME="togglemaster-cluster"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =====================================================================
# Step 0: Verificar credenciais AWS
# =====================================================================
log_info "Verificando credenciais AWS..."
if ! aws sts get-caller-identity &>/dev/null; then
    log_error "Credenciais AWS inválidas. Configure as variáveis de ambiente:"
    echo "  export AWS_ACCESS_KEY_ID=..."
    echo "  export AWS_SECRET_ACCESS_KEY=..."
    echo "  export AWS_SESSION_TOKEN=..."
    exit 1
fi
log_ok "Credenciais AWS válidas"

# =====================================================================
# Step 1: Verificar se cluster EKS existe e limpar recursos K8s
# =====================================================================
log_info "Verificando se cluster EKS '$CLUSTER_NAME' existe..."

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
    log_info "Cluster EKS encontrado. Atualizando kubeconfig..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null

    # Deletar todos os Services tipo LoadBalancer (que criam ELBs na AWS)
    log_info "Buscando Services do tipo LoadBalancer..."
    LB_SERVICES=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('spec', {}).get('type') == 'LoadBalancer':
        ns = item['metadata']['namespace']
        name = item['metadata']['name']
        print(f'{ns}/{name}')
" 2>/dev/null || true)

    if [ -n "$LB_SERVICES" ]; then
        log_warn "Encontrados Services LoadBalancer que bloqueiam o destroy:"
        echo "$LB_SERVICES"
        echo ""

        for svc in $LB_SERVICES; do
            NS=$(echo "$svc" | cut -d/ -f1)
            NAME=$(echo "$svc" | cut -d/ -f2)
            log_info "Deletando Service $NS/$NAME..."
            kubectl delete svc "$NAME" -n "$NS" --timeout=60s 2>/dev/null || true
        done

        # Aguardar os ELBs serem removidos
        log_info "Aguardando LoadBalancers serem removidos da AWS (até 120s)..."
        for i in $(seq 1 24); do
            ELB_COUNT=$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions | length(@)' --output text 2>/dev/null || echo "0")
            NLB_COUNT=$(aws elbv2 describe-load-balancers --query 'LoadBalancers | length(@)' --output text 2>/dev/null || echo "0")
            TOTAL=$((ELB_COUNT + NLB_COUNT))
            if [ "$TOTAL" -eq 0 ]; then
                log_ok "Todos os LoadBalancers removidos"
                break
            fi
            echo "  Aguardando... ($TOTAL LBs restantes, tentativa $i/24)"
            sleep 5
        done
    else
        log_ok "Nenhum Service LoadBalancer encontrado"
    fi

    # Deletar todos os Ingress resources (que podem criar ALBs)
    log_info "Deletando Ingress resources..."
    kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || true

    # Deletar todos os namespaces customizados (exceto system)
    log_info "Deletando namespaces customizados..."
    CUSTOM_NS=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
        grep -v -E '^(default|kube-system|kube-public|kube-node-lease|argocd)$' || true)
    for ns in $CUSTOM_NS; do
        log_info "Deletando namespace $ns..."
        kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
    done

    # Deletar ArgoCD (pode ter criado recursos)
    log_info "Deletando namespace argocd..."
    kubectl delete ns argocd --timeout=120s 2>/dev/null || true

    # Aguardar um pouco mais para ENIs serem liberadas
    log_info "Aguardando 30s para ENIs serem liberadas..."
    sleep 30

else
    log_warn "Cluster EKS '$CLUSTER_NAME' não encontrado. Pulando limpeza K8s."
fi

# =====================================================================
# Step 2: Limpar LoadBalancers órfãos via AWS CLI
# =====================================================================
log_info "Verificando LoadBalancers órfãos..."

# Classic ELBs
ELBS=$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text 2>/dev/null || true)
if [ -n "$ELBS" ]; then
    for elb in $ELBS; do
        log_warn "Deletando Classic ELB órfão: $elb"
        aws elb delete-load-balancer --load-balancer-name "$elb" 2>/dev/null || true
    done
fi

# ALBs/NLBs (v2)
ELBV2_ARNS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null || true)
if [ -n "$ELBV2_ARNS" ]; then
    for arn in $ELBV2_ARNS; do
        NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null)
        log_warn "Deletando ALB/NLB órfão: $NAME"
        # Primeiro deletar listeners
        LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$arn" --query 'Listeners[*].ListenerArn' --output text 2>/dev/null || true)
        for listener in $LISTENERS; do
            aws elbv2 delete-listener --listener-arn "$listener" 2>/dev/null || true
        done
        # Depois deletar o LB
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
    done
    log_info "Aguardando 30s para LBs serem removidos..."
    sleep 30
fi

# Target Groups órfãos
TG_ARNS=$(aws elbv2 describe-target-groups --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null || true)
if [ -n "$TG_ARNS" ]; then
    for tg_arn in $TG_ARNS; do
        TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns "$tg_arn" --query 'TargetGroups[0].TargetGroupName' --output text 2>/dev/null)
        log_warn "Deletando Target Group órfão: $TG_NAME"
        aws elbv2 delete-target-group --target-group-arn "$tg_arn" 2>/dev/null || true
    done
fi

log_ok "Limpeza de LoadBalancers concluída"

# =====================================================================
# Step 3: Limpar ENIs órfãs na VPC
# =====================================================================
log_info "Verificando VPC do ToggleMaster..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=togglemaster-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "VPC encontrada: $VPC_ID. Limpando ENIs órfãs..."

    # Buscar ENIs com status 'available' (desanexadas) na VPC
    ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null || true)

    if [ -n "$ENIS" ]; then
        for eni in $ENIS; do
            log_warn "Deletando ENI órfã: $eni"
            aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
        done
    fi

    # Buscar ENIs 'in-use' que não são do EKS managed (podem ser do LB)
    ENIS_INUSE=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=in-use" \
        --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,Desc:Description,AttachId:Attachment.AttachmentId}' \
        --output json 2>/dev/null || echo "[]")

    ENI_COUNT=$(echo "$ENIS_INUSE" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$ENI_COUNT" -gt 0 ]; then
        log_warn "Encontradas $ENI_COUNT ENIs in-use. Tentando desanexar e deletar..."
        echo "$ENIS_INUSE" | python3 -c "
import json, sys
enis = json.load(sys.stdin)
for eni in enis:
    eni_id = eni['Id']
    attach_id = eni.get('AttachId', '')
    desc = eni.get('Desc', '')
    print(f'{eni_id}|{attach_id}|{desc}')
" | while IFS='|' read -r eni_id attach_id desc; do
            if [ -n "$attach_id" ]; then
                log_info "  Desanexando ENI $eni_id ($desc)..."
                aws ec2 detach-network-interface --attachment-id "$attach_id" --force 2>/dev/null || true
                sleep 5
            fi
            log_info "  Deletando ENI $eni_id..."
            aws ec2 delete-network-interface --network-interface-id "$eni_id" 2>/dev/null || true
        done
    fi

    # Limpar Security Groups que não são o default
    log_info "Limpando Security Groups customizados na VPC..."
    SG_IDS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)

    if [ -n "$SG_IDS" ]; then
        for sg in $SG_IDS; do
            # Primeiro remover regras de ingress/egress que referenciam outros SGs
            log_info "  Limpando regras do SG $sg..."
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
                --query 'SecurityGroupRules[*].SecurityGroupRuleId' --output text 2>/dev/null | \
                tr '\t' '\n' | while read -r rule_id; do
                    [ -n "$rule_id" ] && aws ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids "$rule_id" 2>/dev/null || true
                    [ -n "$rule_id" ] && aws ec2 revoke-security-group-egress --group-id "$sg" --security-group-rule-ids "$rule_id" 2>/dev/null || true
                done
            log_warn "  Deletando SG $sg..."
            aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
        done
    fi

    log_ok "Limpeza de VPC concluída"
else
    log_ok "VPC togglemaster-vpc não encontrada (já deletada)"
fi

# =====================================================================
# Step 4: Terraform Destroy
# =====================================================================
log_info "Verificando terraform state..."
cd "$TERRAFORM_DIR"
terraform init -input=false 2>/dev/null

STATE_COUNT=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

if [ "$STATE_COUNT" -gt 0 ]; then
    log_info "Encontrados $STATE_COUNT recursos no terraform state. Executando destroy..."
    terraform state list 2>/dev/null
    echo ""

    # Tentar force-unlock caso haja lock ativo
    LOCK_ID=$(terraform plan -no-color 2>&1 | grep -oP 'ID:\s+\K[\w-]+' || true)
    if [ -n "$LOCK_ID" ]; then
        log_warn "State locked. Forçando unlock (ID: $LOCK_ID)..."
        printf 'yes\n' | terraform force-unlock "$LOCK_ID" 2>/dev/null || true
    fi

    terraform destroy -auto-approve 2>&1
    DESTROY_EXIT=$?

    if [ $DESTROY_EXIT -eq 0 ]; then
        log_ok "Terraform destroy concluído com sucesso!"
    else
        log_error "Terraform destroy falhou (exit code: $DESTROY_EXIT)"
        log_info "Tentando remover recursos restantes do state..."
        for resource in $(terraform state list 2>/dev/null); do
            log_warn "  Removendo $resource do state..."
            terraform state rm "$resource" 2>/dev/null || true
        done
    fi
else
    log_ok "Terraform state vazio - nada para destruir"
fi

# =====================================================================
# Step 5: Restaurar placeholders nos manifestos
# =====================================================================
log_info "Restaurando placeholders nos manifestos (para manter repo limpo)..."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
GITHUB_USER=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||' | sed 's|https://github.com/||' | cut -d/ -f1)

if [ -n "$ACCOUNT_ID" ]; then
    for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
        DEPLOY_FILE="$PROJECT_DIR/gitops/$svc/deployment.yaml"
        if grep -q "$ACCOUNT_ID" "$DEPLOY_FILE" 2>/dev/null; then
            sed -i.bak "s|$ACCOUNT_ID|<AWS_ACCOUNT_ID>|g" "$DEPLOY_FILE" && rm -f "$DEPLOY_FILE.bak"
        fi
    done
    log_ok "Placeholders ECR restaurados"
fi

if [ -n "$GITHUB_USER" ]; then
    ARGOCD_FILE="$PROJECT_DIR/argocd/applications.yaml"
    if grep -q "github.com/$GITHUB_USER" "$ARGOCD_FILE" 2>/dev/null; then
        sed -i.bak "s|$GITHUB_USER|<GITHUB_USER>|g" "$ARGOCD_FILE" && rm -f "$ARGOCD_FILE.bak"
    fi
    log_ok "Placeholders GitHub restaurados"
fi

# =====================================================================
# Step 6: Verificação final
# =====================================================================
echo ""
echo "========================================="
log_info "VERIFICAÇÃO FINAL"
echo "========================================="

echo -n "VPCs não-default: "
aws ec2 describe-vpcs --filters "Name=is-default,Values=false" --query 'Vpcs | length(@)' --output text 2>/dev/null

echo -n "EKS clusters: "
aws eks list-clusters --query 'clusters | length(@)' --output text 2>/dev/null

echo -n "RDS instances: "
aws rds describe-db-instances --query 'DBInstances | length(@)' --output text 2>/dev/null

echo -n "ElastiCache clusters: "
aws elasticache describe-cache-clusters --query 'CacheClusters | length(@)' --output text 2>/dev/null

echo -n "ECR repositories: "
aws ecr describe-repositories --query 'repositories | length(@)' --output text 2>/dev/null

echo -n "Load Balancers (classic): "
aws elb describe-load-balancers --query 'LoadBalancerDescriptions | length(@)' --output text 2>/dev/null

echo -n "Load Balancers (v2): "
aws elbv2 describe-load-balancers --query 'LoadBalancers | length(@)' --output text 2>/dev/null

echo -n "NAT Gateways: "
aws ec2 describe-nat-gateways --filter "Name=state,Values=available,pending" --query 'NatGateways | length(@)' --output text 2>/dev/null

echo -n "Elastic IPs: "
aws ec2 describe-addresses --query 'Addresses | length(@)' --output text 2>/dev/null

echo ""
echo "========================================="
log_ok "Destruição completa finalizada!"
echo "========================================="
