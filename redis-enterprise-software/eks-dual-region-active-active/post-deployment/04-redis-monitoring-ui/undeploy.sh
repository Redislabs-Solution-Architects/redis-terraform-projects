#!/bin/bash
#==============================================================================
# REDIS ENTERPRISE MONITORING UI CLEANUP SCRIPT
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
ENV_CONFIG="$SCRIPT_DIR/../config.env"

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

command -v aws >/dev/null 2>&1 || fail "aws is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

[ -f "$ENV_CONFIG" ] || fail "config.env not found. Run terraform apply first."
[ -f "$CONFIG_FILE" ] || fail "config.yaml not found."

source "$ENV_CONFIG"

DEPLOYMENT_REGION="$(python3 - "$CONFIG_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}

print(data.get("deployment_region", "region1"))
PY
)"
if [ "$DEPLOYMENT_REGION" = "region1" ]; then
    CONTEXT="$REGION1_CONTEXT"
else
    CONTEXT="$REGION2_CONTEXT"
fi

echo -e "${YELLOW}Removing Redis Monitoring UI + Failover Demo from $CONTEXT...${NC}"

aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null

kubectl delete deployment redis-monitoring-ui -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete service redis-monitoring-ui -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete rolebinding redis-monitoring-ui -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete role redis-monitoring-ui -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete serviceaccount redis-monitoring-ui -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete configmap redis-monitoring-ui-code -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete configmap redis-monitoring-ui-templates -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true
kubectl delete configmap redis-monitoring-ui-config -n "$NAMESPACE" --context="$CONTEXT" --ignore-not-found=true

echo -e "${GREEN}✓ Cleanup complete${NC}"
