#!/bin/bash
# Inject a fault into a service to trigger alerts and self-healing
#
# This script simulates the incident scenario described in the Tech Challenge:
# - Stops a service's database or injects errors
# - Causes the alert to fire
# - Triggers OpsGenie incident + Discord notification + Self-Healing
#
# Usage:
#   ./scripts/self-healing/inject-fault.sh [service]
#   ./scripts/self-healing/inject-fault.sh auth-service

set -e

SERVICE="${1:-auth-service}"
NAMESPACE="togglemaster"

echo "============================================"
echo "  FAULT INJECTION - ToggleMaster"
echo "============================================"
echo "  Target:    $SERVICE"
echo "  Namespace: $NAMESPACE"
echo "  Action:    Scale down to 0 replicas"
echo "============================================"
echo ""
echo "This will cause:"
echo "  1. Service health checks to fail"
echo "  2. Prometheus alert to fire (HighErrorRate5xx / PodNotReady)"
echo "  3. OpsGenie incident to be created"
echo "  4. Discord notification to be sent"
echo "  5. Self-Healing to trigger (rollout restart)"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo ">>> Current state:"
kubectl get pods -n $NAMESPACE -l app=$SERVICE
echo ""

echo ">>> Injecting fault: scaling $SERVICE to 0 replicas..."
kubectl scale deployment/$SERVICE -n $NAMESPACE --replicas=0

echo ""
echo ">>> Fault injected! The service is now down."
echo ""
echo ">>> Monitoring:"
echo "  - Watch pods:  kubectl get pods -n $NAMESPACE -w"
echo "  - Watch alerts: Open Grafana -> Alerting -> Alert Rules"
echo "  - OpsGenie:    https://app.opsgenie.com/alert"
echo ""
echo ">>> To manually restore (if self-healing doesn't trigger):"
echo "  kubectl scale deployment/$SERVICE -n $NAMESPACE --replicas=2"
echo ""
echo ">>> The alert should fire within ~2-5 minutes."
echo ">>> Self-healing will then restore the service automatically."
