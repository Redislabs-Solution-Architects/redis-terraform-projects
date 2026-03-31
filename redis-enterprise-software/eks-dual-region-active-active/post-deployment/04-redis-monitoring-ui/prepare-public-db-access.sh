#!/bin/bash
#==============================================================================
# PREPARE PUBLIC DB ACCESS FOR LOCAL FAILOVER DEMO
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_CONFIG="$SCRIPT_DIR/../config.env"

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_for_lb_hostname() {
    local context="$1"
    local service_name="$2"
    local timeout=900
    local elapsed=0
    local hostname=""

    while [ "$elapsed" -lt "$timeout" ]; do
        hostname="$(kubectl get svc "$service_name" -n "$NAMESPACE" --context "$context" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
        if [ -n "$hostname" ]; then
            printf '%s\n' "$hostname"
            return
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    fail "Timed out waiting for LoadBalancer hostname on service $service_name in context $context."
}

get_route53_zone_id() {
    aws route53 list-hosted-zones-by-name \
        --dns-name "$INGRESS_DOMAIN" \
        --max-items 10 \
        --profile "$AWS_PROFILE" \
        --query "HostedZones[?Name == '${INGRESS_DOMAIN}.'] | [0].Id" \
        --output text 2>/dev/null | sed 's#.*/##'
}

upsert_cname_record() {
    local fqdn="$1"
    local target="$2"
    local zone_id="$3"
    local change_batch

    change_batch="$(mktemp)"
    cat > "$change_batch" <<EOF
{
  "Comment": "Expose Redis CRDB for local failover demo",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${fqdn}",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "${target}"
          }
        ]
      }
    }
  ]
}
EOF

    aws route53 change-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --profile "$AWS_PROFILE" \
        --change-batch "file://$change_batch" >/dev/null

    rm -f "$change_batch"
}

echo ""
echo "=========================================================================="
echo "  Prepare Public DB Access For Local Failover Demo"
echo "=========================================================================="
echo ""

require_command aws
require_command kubectl

[ -f "$ENV_CONFIG" ] || fail "config.env not found."
source "$ENV_CONFIG"

export ASDF_KUBECTL_VERSION="${ASDF_KUBECTL_VERSION:-1.31.14}"

echo -e "${BLUE}🔧 Configuring kubectl contexts...${NC}"
aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null

echo -e "${BLUE}🔍 Detecting CRDB service...${NC}"
DATABASE_NAME="$(kubectl get reaadb -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$DATABASE_NAME" ] || DATABASE_NAME="$CRDB_NAME"
[ -n "$DATABASE_NAME" ] || fail "Could not determine the database name."

DATABASE_PORT="$(kubectl get svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
[ -n "$DATABASE_PORT" ] || fail "Could not determine the database port."

ZONE_ID="$(get_route53_zone_id)"
[ -n "$ZONE_ID" ] || fail "Could not find Route53 zone for $INGRESS_DOMAIN."

for region in region1 region2; do
    if [ "$region" = "region1" ]; then
        context="$REGION1_CONTEXT"
        fqdn="${DATABASE_NAME}.db.region1.${INGRESS_DOMAIN}"
    else
        context="$REGION2_CONTEXT"
        fqdn="${DATABASE_NAME}.db.region2.${INGRESS_DOMAIN}"
    fi

    echo -e "${BLUE}🌐 Ensuring LoadBalancer service for $region...${NC}"
    kubectl patch svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$context" --type merge -p "{
      \"metadata\": {
        \"annotations\": {
          \"service.beta.kubernetes.io/aws-load-balancer-type\": \"nlb\",
          \"service.beta.kubernetes.io/aws-load-balancer-scheme\": \"internet-facing\",
          \"service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled\": \"true\"
        }
      },
      \"spec\": {
        \"type\": \"LoadBalancer\"
      }
    }" >/dev/null

    lb_hostname="$(wait_for_lb_hostname "$context" "$DATABASE_NAME")"
    echo "  Service hostname: $lb_hostname"

    echo -e "${BLUE}🧭 Upserting Route53 record $fqdn -> $lb_hostname${NC}"
    upsert_cname_record "$fqdn" "$lb_hostname" "$ZONE_ID"
done

echo ""
echo -e "${GREEN}✅ Public CRDB access prepared${NC}"
echo "  Region 1 DB FQDN: ${DATABASE_NAME}.db.region1.${INGRESS_DOMAIN}:${DATABASE_PORT}"
echo "  Region 2 DB FQDN: ${DATABASE_NAME}.db.region2.${INGRESS_DOMAIN}:${DATABASE_PORT}"
echo ""
echo "Next:"
echo "  1. Wait 1-2 minutes for NLB provisioning / DNS propagation"
echo "  2. Re-run ./run-local.sh"
