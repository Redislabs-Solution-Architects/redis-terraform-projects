#!/bin/bash

#==============================================================================
# CONFIGURE GRAFANA WITH DUAL PROMETHEUS DATASOURCES
#==============================================================================
# This script configures Grafana to connect to both Prometheus instances
# (local and remote region) for unified monitoring
#
# Usage:
#   ./05-configure-dual-datasources.sh [region1|region2]
#
# This should be run AFTER deploying the monitoring stack to both regions
#==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.env"

fail() {
    echo -e "${RED}❌ ERROR: $1${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

GRAFANA_REGION="${1:-region1}"  # Which region's Grafana to configure

echo ""
echo "=========================================================================="
echo "  Configure Grafana with Dual Prometheus Datasources"
echo "=========================================================================="
echo ""

# Validate deployment target
if [[ ! "$GRAFANA_REGION" =~ ^(region1|region2)$ ]]; then
    echo -e "${RED}❌ ERROR: Invalid region: $GRAFANA_REGION${NC}"
    echo ""
    echo "Usage: $0 [region1|region2]"
    echo ""
    echo "Examples:"
    echo "  $0 region1   # Configure Grafana in region 1 to see both regions"
    echo "  $0 region2   # Configure Grafana in region 2 to see both regions"
    echo ""
    exit 1
fi

# Load configuration
[ -f "$CONFIG_FILE" ] || fail "config.env not found at $CONFIG_FILE"

source "$CONFIG_FILE"

require_command aws
require_command kubectl
require_command mktemp

[ -n "${AWS_PROFILE:-}" ] || fail "AWS_PROFILE is not set in config.env"
[ -n "${REGION1_CONTEXT:-}" ] || fail "REGION1_CONTEXT is not set in config.env"
[ -n "${REGION2_CONTEXT:-}" ] || fail "REGION2_CONTEXT is not set in config.env"
[ -n "${REGION1_CLUSTER_NAME:-}" ] || fail "REGION1_CLUSTER_NAME is not set in config.env"
[ -n "${REGION2_CLUSTER_NAME:-}" ] || fail "REGION2_CLUSTER_NAME is not set in config.env"

aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null

echo -e "${BLUE}📋 Configuration:${NC}"
echo "  Configuring Grafana in: $GRAFANA_REGION"
echo "  Region 1: ${AWS_REGION1} - $REGION1_CLUSTER_NAME"
echo "  Region 2: ${AWS_REGION2} - $REGION2_CLUSTER_NAME"
echo ""

# Determine contexts
if [ "$GRAFANA_REGION" = "region1" ]; then
    GRAFANA_CONTEXT="$REGION1_CONTEXT"
    REMOTE_CONTEXT="$REGION2_CONTEXT"
    REMOTE_REGION="$AWS_REGION2"
    LOCAL_REGION="$AWS_REGION1"
else
    GRAFANA_CONTEXT="$REGION2_CONTEXT"
    REMOTE_CONTEXT="$REGION1_CONTEXT"
    REMOTE_REGION="$AWS_REGION1"
    LOCAL_REGION="$AWS_REGION2"
fi

echo -e "${BLUE}🔍 Step 1: Getting remote Prometheus LoadBalancer URL...${NC}"

# Check if LoadBalancer service exists in remote region
REMOTE_LB=$(kubectl get svc prometheus-external -n monitoring --context $REMOTE_CONTEXT -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -z "$REMOTE_LB" ]; then
    echo -e "${YELLOW}⚠️  LoadBalancer service not found in remote region${NC}"
    echo ""
    echo "Please deploy the LoadBalancer service first:"
    echo "  kubectl apply -f 04-prometheus-loadbalancer.yaml --context $REMOTE_CONTEXT"
    echo ""
    echo "Then wait for the LoadBalancer to be provisioned:"
    echo "  kubectl get svc prometheus-external -n monitoring --context $REMOTE_CONTEXT -w"
    echo ""
    exit 1
fi

kubectl get deployment grafana -n monitoring --context "$GRAFANA_CONTEXT" >/dev/null 2>&1 || fail "Grafana deployment not found in $GRAFANA_REGION. Deploy monitoring with --with-grafana first."

echo -e "${GREEN}✅ Remote Prometheus LoadBalancer: $REMOTE_LB${NC}"
echo ""

echo -e "${BLUE}📝 Step 2: Creating Grafana datasource configuration...${NC}"

# Create updated datasource configuration
TMP_DATASOURCES="$(mktemp)"
trap 'rm -f "$TMP_DATASOURCES"' EXIT

cat > "$TMP_DATASOURCES" <<EOF
apiVersion: 1
datasources:
  # Local Prometheus (${LOCAL_REGION})
  - name: Prometheus-${LOCAL_REGION}
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: "15s"
    uid: prometheus-local

  # Remote Prometheus (${REMOTE_REGION})
  - name: Prometheus-${REMOTE_REGION}
    type: prometheus
    access: proxy
    url: http://${REMOTE_LB}:9090
    editable: true
    jsonData:
      timeInterval: "15s"
    uid: prometheus-remote
EOF

echo -e "${GREEN}✅ Datasource configuration created${NC}"
echo ""

echo -e "${BLUE}🔄 Step 3: Updating Grafana ConfigMap...${NC}"

# Update the ConfigMap
kubectl create configmap grafana-datasources \
  --from-file=prometheus.yaml="$TMP_DATASOURCES" \
  --dry-run=client -o yaml | \
  kubectl apply -f - --context $GRAFANA_CONTEXT -n monitoring

echo -e "${GREEN}✅ ConfigMap updated${NC}"
echo ""

echo -e "${BLUE}🔄 Step 4: Restarting Grafana to apply changes...${NC}"

kubectl rollout restart deployment/grafana -n monitoring --context $GRAFANA_CONTEXT
kubectl rollout status deployment/grafana -n monitoring --context $GRAFANA_CONTEXT --timeout=120s

echo -e "${GREEN}✅ Grafana restarted${NC}"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Grafana Configured with Dual Datasources!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📊 Verification:${NC}"
echo ""
echo "1. Access Grafana:"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:3000 --context $GRAFANA_CONTEXT"
echo "   Open: http://localhost:3000"
echo "   Username: admin"
echo "   Password: kubectl get secret grafana-admin -n monitoring --context $GRAFANA_CONTEXT -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "2. Verify datasources:"
echo "   - Go to Configuration → Data Sources"
echo "   - You should see:"
echo "     • Prometheus-${LOCAL_REGION} (default)"
echo "     • Prometheus-${REMOTE_REGION}"
echo ""
echo "3. Test queries:"
echo "   - Go to Explore"
echo "   - Select each datasource and run: redis_up"
echo "   - You should see metrics from both regions"
echo ""
