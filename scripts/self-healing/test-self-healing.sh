#!/bin/bash
# Test the self-healing workflow by triggering a repository_dispatch event
#
# Prerequisites:
#   - gh CLI authenticated
#   - GitHub Actions secrets configured (AWS_*, DISCORD_WEBHOOK_URL)
#
# Usage:
#   ./scripts/self-healing/test-self-healing.sh [service-name]
#   ./scripts/self-healing/test-self-healing.sh auth-service

set -e

SERVICE="${1:-auth-service}"
REPO="rivachef/TC4-ToggleMaster"

echo "============================================"
echo "  Self-Healing Test Trigger"
echo "============================================"
echo "  Repository: $REPO"
echo "  Service:    $SERVICE"
echo "  Alert:      TestAlert (manual)"
echo "============================================"
echo ""

echo "Triggering repository_dispatch event..."
gh api "repos/$REPO/dispatches" \
  -f event_type=self-healing \
  -f "client_payload[service]=$SERVICE" \
  -f "client_payload[alert]=TestAlert-ManualTrigger"

echo ""
echo "Dispatch event sent successfully!"
echo ""
echo "Monitor the workflow at:"
echo "  https://github.com/$REPO/actions/workflows/self-healing.yaml"
echo ""
echo "Or via CLI:"
echo "  gh run list --workflow=self-healing.yaml --repo=$REPO"
