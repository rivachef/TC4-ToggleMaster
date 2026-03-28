#!/bin/bash
# Script to install the monitoring stack via Helm
# Run this after the EKS cluster is active and kubectl is configured

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MONITORING_DIR="$PROJECT_DIR/gitops/monitoring"

echo "============================================"
echo "  ToggleMaster - Monitoring Stack Installer"
echo "  Phase 4: Observability & Self-Healing"
echo "============================================"
echo ""

# -------------------------------------------------------
# Step 1: Create monitoring namespace
# -------------------------------------------------------
echo "[1/6] Creating monitoring namespace..."
kubectl apply -f "$MONITORING_DIR/namespace.yaml"

# -------------------------------------------------------
# Step 2: Add Helm repositories
# -------------------------------------------------------
echo "[2/6] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# -------------------------------------------------------
# Step 3: Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# -------------------------------------------------------
echo "[3/6] Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "$MONITORING_DIR/prometheus/values.yaml" \
  --wait --timeout 10m

# -------------------------------------------------------
# Step 4: Install Loki
# -------------------------------------------------------
echo "[4/6] Installing Loki..."
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values "$MONITORING_DIR/loki/values.yaml" \
  --wait --timeout 10m

# -------------------------------------------------------
# Step 5: Install Promtail
# -------------------------------------------------------
echo "[5/6] Installing Promtail..."
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --values "$MONITORING_DIR/promtail/values.yaml" \
  --wait --timeout 5m

# -------------------------------------------------------
# Step 6: Install OpenTelemetry Collector
# -------------------------------------------------------
echo "[6/6] Installing OpenTelemetry Collector..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --values "$MONITORING_DIR/otel-collector/values.yaml" \
  --wait --timeout 5m

echo ""
echo "============================================"
echo "  Monitoring Stack Installed Successfully!"
echo "============================================"
echo ""

# -------------------------------------------------------
# Post-install: Apply Alertmanager custom config
# MUST be after Helm install so the secret overrides Helm's default
# -------------------------------------------------------
echo "Applying Alertmanager custom configuration..."
ALERTING_DIR="$MONITORING_DIR/alerting"
AM_SECRET_FILE="$ALERTING_DIR/alertmanager-secret.yaml"
if [ -f "$AM_SECRET_FILE" ]; then
  kubectl apply --server-side --force-conflicts -f "$AM_SECRET_FILE"
  echo "  [OK] Alertmanager config applied (PagerDuty + Discord + Self-Healing)"
else
  echo "  [AVISO] $AM_SECRET_FILE not found — alerting not configured"
fi

# -------------------------------------------------------
# Post-install: Apply PrometheusRules (custom alert rules)
# -------------------------------------------------------
echo "Applying ToggleMaster alert rules..."
if [ -f "$ALERTING_DIR/prometheus-rules.yaml" ]; then
  kubectl apply -f "$ALERTING_DIR/prometheus-rules.yaml"
  echo "  [OK] PrometheusRules applied"
fi

# -------------------------------------------------------
# Post-install: Load Grafana Dashboard
# -------------------------------------------------------
echo "Loading ToggleMaster Grafana dashboard..."

# Resolve Loki datasource UID dynamically (Grafana assigns random UIDs per install)
echo "  Waiting for Grafana to be ready..."
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=120s >/dev/null 2>&1

GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
LOKI_UID=""
for i in $(seq 1 12); do
  LOKI_UID=$(kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
    curl -sf http://localhost:3000/api/datasources -u admin:togglemaster2024 2>/dev/null | \
    python3 -c "import sys,json; ds=json.load(sys.stdin); print(next((d['uid'] for d in ds if d['type']=='loki'),''))" 2>/dev/null)
  [ -n "$LOKI_UID" ] && break
  echo "  Waiting for Loki datasource... (${i}/12)"
  sleep 5
done

if [ -z "$LOKI_UID" ]; then
  echo "  [AVISO] Loki datasource UID not found — log panels may not work."
  echo "    Fix manually: Grafana > Dashboard > Edit panel > change datasource to Loki"
  LOKI_UID="loki"
fi
echo "  Loki datasource UID: $LOKI_UID"

# Replace placeholder in dashboard JSON and load as ConfigMap
DASHBOARD_TMP=$(mktemp)
sed "s|<LOKI_DS_UID>|$LOKI_UID|g" "$MONITORING_DIR/grafana/dashboards/togglemaster-overview.json" > "$DASHBOARD_TMP"

kubectl create configmap togglemaster-dashboard \
  --from-file=togglemaster-overview.json="$DASHBOARD_TMP" \
  --namespace monitoring \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml | \
  kubectl annotate --local -f - grafana_folder=ToggleMaster -o yaml | \
  kubectl apply -f -

rm -f "$DASHBOARD_TMP"

echo ""
echo "--- Access Information ---"
echo ""
echo "Grafana:"
echo "  URL:      kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo "  User:     admin"
echo "  Password: togglemaster2024"
echo ""
echo "Prometheus:"
echo "  Internal: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
echo ""
echo "Loki:"
echo "  Internal: http://loki.monitoring.svc.cluster.local:3100"
echo ""
echo "OTel Collector:"
echo "  gRPC:     otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317"
echo "  HTTP:     otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4318"
echo ""
echo "--- IMPORTANT ---"
echo "Don't forget to apply the New Relic secret:"
echo "  cp gitops/monitoring/newrelic-secret.yaml.example gitops/monitoring/newrelic-secret.yaml"
echo "  # Edit with your license key"
echo "  kubectl apply -f gitops/monitoring/newrelic-secret.yaml"
echo ""
