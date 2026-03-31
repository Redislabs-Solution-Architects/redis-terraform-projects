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


def parse_scalar(raw_value):
    value = raw_value.strip()
    if not value:
        return ""
    if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
        return value[1:-1]
    return value


def load_simple_yaml(path):
    root = {}
    stack = [(-1, root)]

    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            indent = len(line) - len(line.lstrip(" "))
            stripped = line.strip()
            if ":" not in stripped:
                continue

            key, raw_value = stripped.split(":", 1)
            key = key.strip()
            value = raw_value.strip()

            while stack and indent <= stack[-1][0]:
                stack.pop()

            parent = stack[-1][1]
            if value == "":
                parent[key] = {}
                stack.append((indent, parent[key]))
            else:
                parent[key] = parse_scalar(value)

    return root


data = load_simple_yaml(sys.argv[1])

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
