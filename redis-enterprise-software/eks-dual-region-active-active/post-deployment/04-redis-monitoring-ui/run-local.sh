#!/bin/bash
#==============================================================================
# REDIS ENTERPRISE MONITORING UI + FAILOVER DEMO - LOCAL RUNNER
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
ENV_CONFIG="$SCRIPT_DIR/../config.env"
TMP_DIR="$(mktemp -d)"
RUNTIME_CONFIG="$TMP_DIR/local-config.yaml"
trap 'rm -rf "$TMP_DIR"' EXIT
GENERATE_ONLY="false"

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

if [ "${1:-}" = "--generate-only" ]; then
    GENERATE_ONLY="true"
elif [ -n "${1:-}" ]; then
    fail "Unsupported argument: $1"
fi

read_cfg() {
    local path="$1"
    local default_value="$2"
    python3 - "$CONFIG_FILE" "$path" "$default_value" <<'PY'
import sys

config_file, raw_path, default_value = sys.argv[1:]


def parse_scalar(raw_value):
    value = raw_value.strip()
    if not value:
        return ""
    if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
        return value[1:-1]
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
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


data = load_simple_yaml(config_file)

keys = [part for part in raw_path.split(".") if part]
value = data
for key in keys:
    if not isinstance(value, dict) or key not in value:
        value = default_value
        break
    value = value[key]

if value in (None, ""):
    value = default_value

if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

strip_dot() {
    printf '%s' "$1" | sed 's/\.$//'
}

yaml_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

detect_monitoring_secret() {
    local context="$1"
    local rec_name="$2"
    local prefixed="redis-enterprise-$rec_name"
    local discovered=""

    if kubectl get secret "$rec_name" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1; then
        echo "$rec_name"
        return
    fi

    if kubectl get secret "$prefixed" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1; then
        echo "$prefixed"
        return
    fi

    discovered="$(kubectl get secret -n "$NAMESPACE" --context "$context" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | rg "${rec_name}$" | head -1 || true)"
    [ -n "$discovered" ] || fail "Could not find an API credential secret for $rec_name in context $context."
    echo "$discovered"
}

secret_data() {
    local context="$1"
    local secret_name="$2"
    local key="$3"

    kubectl get secret "$secret_name" -n "$NAMESPACE" --context "$context" -o "jsonpath={.data.$key}" 2>/dev/null | base64 -d || true
}

get_route53_zone_id() {
    aws route53 list-hosted-zones-by-name \
        --dns-name "$INGRESS_DOMAIN" \
        --max-items 10 \
        --profile "$AWS_PROFILE" \
        --query "HostedZones[?Name == '${INGRESS_DOMAIN}.'] | [0].Id" \
        --output text 2>/dev/null | sed 's#.*/##'
}

get_route53_record_target() {
    local fqdn="$1"
    local zone_id="$2"

    if [[ "$fqdn" == \** ]]; then
        local suffix="${fqdn#*.}"
        aws route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --profile "$AWS_PROFILE" \
            --query "ResourceRecordSets[?Type == 'CNAME'].[Name,ResourceRecords[0].Value]" \
            --output text 2>/dev/null | awk -v suffix=".$suffix." '$1 ~ suffix"$" { print $2; exit }'
        return
    fi

    aws route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --profile "$AWS_PROFILE" \
        --query "ResourceRecordSets[?Name == '${fqdn}.'] | [0].ResourceRecords[0].Value" \
        --output text 2>/dev/null
}

resolve_public_target() {
    local zone_id="$1"
    shift
    local candidate=""
    local target=""

    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        target="$(get_route53_record_target "$candidate" "$zone_id")"
        if [ -n "$target" ] && [ "$target" != "None" ]; then
            printf '%s|%s\n' "$candidate" "$(strip_dot "$target")"
            return
        fi
    done

    fail "Could not resolve any Route53 record target for candidates: $*"
}

load_balancer_subnets_by_dns() {
    local region="$1"
    local dns_name="$2"
    aws elbv2 describe-load-balancers \
        --region "$region" \
        --profile "$AWS_PROFILE" \
        --query "LoadBalancers[?DNSName==\`$dns_name\`].AvailabilityZones[].SubnetId" \
        --output text 2>/dev/null
}

nacl_id_for_subnets() {
    local region="$1"
    shift
    local subnet_csv
    subnet_csv="$(printf '%s\n' "$@" | paste -sd, -)"
    aws ec2 describe-network-acls \
        --filters "Name=association.subnet-id,Values=$subnet_csv" \
        --region "$region" \
        --profile "$AWS_PROFILE" \
        --query 'NetworkAcls[0].NetworkAclId' \
        --output text 2>/dev/null
}

detect_public_ip() {
    curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]'
}

echo ""
echo "=========================================================================="
echo "  Redis Monitoring UI + Failover Demo - Local Runner"
echo "=========================================================================="
echo ""

require_command aws
require_command kubectl
require_command python3
require_command rg
require_command curl

[ -f "$ENV_CONFIG" ] || fail "config.env not found."
[ -f "$CONFIG_FILE" ] || fail "config.yaml not found."

echo -e "${BLUE}📋 Loading configuration from config.env...${NC}"
source "$ENV_CONFIG"

export ASDF_KUBECTL_VERSION="${ASDF_KUBECTL_VERSION:-1.31.14}"

APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8080}"
REFRESH_INTERVAL="$(read_cfg 'refresh_interval' '5')"
DATABASE_OVERRIDE="$(read_cfg 'database_name' '')"
DATABASE_PORT_OVERRIDE="$(read_cfg 'database_port' '0')"
PREFERRED_REGION="$(read_cfg 'failover.preferred_region' 'region1')"
FAIL_WINDOW="$(read_cfg 'failover.failures_detection_window_seconds' '2')"
MIN_FAILURES="$(read_cfg 'failover.min_num_failures' '2')"
FAIL_RATE="$(read_cfg 'failover.failure_rate_threshold' '0.5')"
HEALTH_INTERVAL="$(read_cfg 'failover.health_check_interval_seconds' '5')"
HEALTH_PROBES="$(read_cfg 'failover.health_check_probes' '3')"
HEALTH_PROBE_DELAY="$(read_cfg 'failover.health_check_probe_delay_seconds' '0.5')"
INITIAL_HEALTH_POLICY="$(read_cfg 'failover.initial_health_check_policy' 'one_available')"
HEALTH_POLICY="$(read_cfg 'failover.health_check_policy' 'healthy_any')"
AUTO_FALLBACK="$(read_cfg 'failover.auto_fallback_interval_seconds' '10')"
FAILOVER_ATTEMPTS="$(read_cfg 'failover.failover_attempts' '3')"
FAILOVER_DELAY="$(read_cfg 'failover.failover_delay_seconds' '1')"
GRACE_PERIOD="$(read_cfg 'failover.grace_period_seconds' '5')"
COMMAND_RETRIES="$(read_cfg 'failover.command_retries' '1')"
REDIS_CONNECT_TIMEOUT="$(read_cfg 'failover.redis_connect_timeout_seconds' '3')"
REDIS_SOCKET_TIMEOUT="$(read_cfg 'failover.redis_socket_timeout_seconds' '3')"
USE_LAG_AWARE="$(read_cfg 'failover.use_lag_aware_health_check' 'false')"
LAG_TOLERANCE="$(read_cfg 'failover.lag_tolerance_ms' '100')"
LAG_API_PORT="$(read_cfg 'failover.lag_aware_rest_api_port' '9443')"
LAG_VERIFY_TLS="$(read_cfg 'failover.lag_aware_verify_tls' 'false')"
AUTO_START="$(read_cfg 'demo.auto_start' 'false')"
KEY_PREFIX="$(read_cfg 'demo.key_prefix' 'redis-ca-demo')"
WORKLOAD_INTERVAL="$(read_cfg 'demo.workload_interval_seconds' '2')"
WORKLOAD_COMMAND_ATTEMPTS="$(read_cfg 'demo.workload_command_attempts' '2')"
EVENT_LOG_RETENTION="$(read_cfg 'demo.event_log_retention' '600')"
EVENT_LOG_PAUSE_SECONDS="$(read_cfg 'demo.event_log_pause_seconds' '10')"

echo -e "${BLUE}🔧 Configuring kubectl contexts...${NC}"
aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null

echo -e "${BLUE}🔍 Auto-detecting database...${NC}"
if [ -n "$DATABASE_OVERRIDE" ]; then
    DATABASE_NAME="$DATABASE_OVERRIDE"
else
    DATABASE_NAME="$(kubectl get reaadb -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$DATABASE_NAME" ] || DATABASE_NAME="$CRDB_NAME"
fi
[ -n "$DATABASE_NAME" ] || fail "Could not determine the database name."

if [ "$DATABASE_PORT_OVERRIDE" != "0" ]; then
    DATABASE_PORT="$DATABASE_PORT_OVERRIDE"
else
    DATABASE_PORT="$(kubectl get svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    [ -n "$DATABASE_PORT" ] || DATABASE_PORT="$(kubectl get svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$REGION2_CONTEXT" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
fi
[ -n "$DATABASE_PORT" ] || fail "Could not determine the database port."

ZONE_ID="$(get_route53_zone_id)"
[ -n "$ZONE_ID" ] || fail "Could not find Route53 hosted zone for $INGRESS_DOMAIN."

REGION1_API_SECRET="$(detect_monitoring_secret "$REGION1_CONTEXT" "$REGION1_REC_NAME")"
REGION2_API_SECRET="$(detect_monitoring_secret "$REGION2_CONTEXT" "$REGION2_REC_NAME")"
REGION1_API_USER="$(secret_data "$REGION1_CONTEXT" "$REGION1_API_SECRET" username)"
REGION1_API_PASS="$(secret_data "$REGION1_CONTEXT" "$REGION1_API_SECRET" password)"
REGION2_API_USER="$(secret_data "$REGION2_CONTEXT" "$REGION2_API_SECRET" username)"
REGION2_API_PASS="$(secret_data "$REGION2_CONTEXT" "$REGION2_API_SECRET" password)"
[ -n "$REGION1_API_USER" ] || fail "Could not read Region 1 API username."
[ -n "$REGION1_API_PASS" ] || fail "Could not read Region 1 API password."
if [ -z "$REGION2_API_USER" ]; then
    echo -e "${YELLOW}⚠️ Region 2 API username not found in $REGION2_API_SECRET. Falling back to Region 1 API username.${NC}"
    REGION2_API_USER="$REGION1_API_USER"
fi
if [ -z "$REGION2_API_PASS" ]; then
    echo -e "${YELLOW}⚠️ Region 2 API password not found in $REGION2_API_SECRET. Falling back to Region 1 API password.${NC}"
    REGION2_API_PASS="$REGION1_API_PASS"
fi

REGION1_API_PUBLIC_FQDN="${REGION1_API_FQDN:-api.region1.${INGRESS_DOMAIN}}"
REGION2_API_PUBLIC_FQDN="${REGION2_API_FQDN:-api.region2.${INGRESS_DOMAIN}}"
REGION1_DB_PUBLIC_FQDN="${DATABASE_NAME}.db.region1.${INGRESS_DOMAIN}"
REGION2_DB_PUBLIC_FQDN="${DATABASE_NAME}.db.region2.${INGRESS_DOMAIN}"

IFS='|' read -r REGION1_API_DISPLAY REGION1_API_TARGET <<<"$(resolve_public_target "$ZONE_ID" "$REGION1_API_PUBLIC_FQDN")"
IFS='|' read -r REGION2_API_DISPLAY REGION2_API_TARGET <<<"$(resolve_public_target "$ZONE_ID" "$REGION2_API_PUBLIC_FQDN")"
IFS='|' read -r REGION1_DB_DISPLAY REGION1_DB_TARGET <<<"$(resolve_public_target "$ZONE_ID" "$REGION1_DB_PUBLIC_FQDN")"
IFS='|' read -r REGION2_DB_DISPLAY REGION2_DB_TARGET <<<"$(resolve_public_target "$ZONE_ID" "$REGION2_DB_PUBLIC_FQDN")"
REGION1_DB_SUBNETS=($(load_balancer_subnets_by_dns "$AWS_REGION1" "$REGION1_DB_TARGET"))
REGION2_DB_SUBNETS=($(load_balancer_subnets_by_dns "$AWS_REGION2" "$REGION2_DB_TARGET"))
[ "${#REGION1_DB_SUBNETS[@]}" -gt 0 ] || fail "Could not determine Region 1 DB load balancer subnets."
[ "${#REGION2_DB_SUBNETS[@]}" -gt 0 ] || fail "Could not determine Region 2 DB load balancer subnets."
REGION1_NACL_ID="$(nacl_id_for_subnets "$AWS_REGION1" "${REGION1_DB_SUBNETS[@]}")"
REGION2_NACL_ID="$(nacl_id_for_subnets "$AWS_REGION2" "${REGION2_DB_SUBNETS[@]}")"
[ -n "$REGION1_NACL_ID" ] || fail "Could not determine Region 1 network ACL."
[ -n "$REGION2_NACL_ID" ] || fail "Could not determine Region 2 network ACL."
CLIENT_PUBLIC_IP="$(detect_public_ip || true)"

DB_SECRET_NAME=""
DB_USERNAME=""
DB_PASSWORD=""
if kubectl get secret "${DATABASE_NAME}-password" -n "$NAMESPACE" --context "$REGION1_CONTEXT" >/dev/null 2>&1; then
    DB_SECRET_NAME="${DATABASE_NAME}-password"
    DB_USERNAME="$(secret_data "$REGION1_CONTEXT" "$DB_SECRET_NAME" username)"
    DB_PASSWORD="$(secret_data "$REGION1_CONTEXT" "$DB_SECRET_NAME" password)"
fi

if [ "$GENERATE_ONLY" != "true" ]; then
python3 - <<'PY' >/dev/null 2>&1 || fail "Python dependencies missing. Run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
import flask
import kubernetes
import pybreaker
import redis
import requests
import yaml
PY
fi

cat > "$RUNTIME_CONFIG" <<EOF
deployment_region: local
namespace: $NAMESPACE
refresh_interval: $REFRESH_INTERVAL
database_name: $DATABASE_NAME

regions:
  region1:
    name: $AWS_REGION1
    api_endpoint: $(yaml_quote "$REGION1_API_DISPLAY")
    api_connect_target: $(yaml_quote "$REGION1_API_TARGET")
    api_display_endpoint: $(yaml_quote "$REGION1_API_DISPLAY")
    api_port: 443
    api_username: $(yaml_quote "$REGION1_API_USER")
    api_password: $(yaml_quote "$REGION1_API_PASS")
    redis_endpoint: $(yaml_quote "$REGION1_DB_TARGET")
    redis_display_endpoint: $(yaml_quote "$REGION1_DB_DISPLAY")
    redis_port: $DATABASE_PORT
    redis_weight: $( [ "$PREFERRED_REGION" = "region1" ] && echo "1.0" || echo "0.5" )
    health_check_url: $(yaml_quote "https://$REGION1_API_DISPLAY")
  region2:
    name: $AWS_REGION2
    api_endpoint: $(yaml_quote "$REGION2_API_DISPLAY")
    api_connect_target: $(yaml_quote "$REGION2_API_TARGET")
    api_display_endpoint: $(yaml_quote "$REGION2_API_DISPLAY")
    api_port: 443
    api_username: $(yaml_quote "$REGION2_API_USER")
    api_password: $(yaml_quote "$REGION2_API_PASS")
    redis_endpoint: $(yaml_quote "$REGION2_DB_TARGET")
    redis_display_endpoint: $(yaml_quote "$REGION2_DB_DISPLAY")
    redis_port: $DATABASE_PORT
    redis_weight: $( [ "$PREFERRED_REGION" = "region2" ] && echo "1.0" || echo "0.5" )
    health_check_url: $(yaml_quote "https://$REGION2_API_DISPLAY")

redis:
  port: $DATABASE_PORT
  tls: true
  verify_tls: false
  database_secret_name: ""
  username: $(yaml_quote "$DB_USERNAME")
  password: $(yaml_quote "$DB_PASSWORD")

failover:
  preferred_region: $PREFERRED_REGION
  failures_detection_window_seconds: $FAIL_WINDOW
  min_num_failures: $MIN_FAILURES
  failure_rate_threshold: $FAIL_RATE
  health_check_interval_seconds: $HEALTH_INTERVAL
  health_check_probes: $HEALTH_PROBES
  health_check_probe_delay_seconds: $HEALTH_PROBE_DELAY
  initial_health_check_policy: $INITIAL_HEALTH_POLICY
  health_check_policy: $HEALTH_POLICY
  auto_fallback_interval_seconds: $AUTO_FALLBACK
  failover_attempts: $FAILOVER_ATTEMPTS
  failover_delay_seconds: $FAILOVER_DELAY
  grace_period_seconds: $GRACE_PERIOD
  command_retries: $COMMAND_RETRIES
  redis_connect_timeout_seconds: $REDIS_CONNECT_TIMEOUT
  redis_socket_timeout_seconds: $REDIS_SOCKET_TIMEOUT
  use_lag_aware_health_check: $USE_LAG_AWARE
  lag_tolerance_ms: $LAG_TOLERANCE
  lag_aware_rest_api_port: $LAG_API_PORT
  lag_aware_verify_tls: $LAG_VERIFY_TLS

demo:
  auto_start: $AUTO_START
  key_prefix: $KEY_PREFIX
  workload_interval_seconds: $WORKLOAD_INTERVAL
  workload_command_attempts: $WORKLOAD_COMMAND_ATTEMPTS
  event_log_retention: $EVENT_LOG_RETENTION
  event_log_pause_seconds: $EVENT_LOG_PAUSE_SECONDS
  outage_mode: infrastructure
  infrastructure_outage:
    enabled: true
    aws_profile: $(yaml_quote "$AWS_PROFILE")
    client_public_ip: $(yaml_quote "$CLIENT_PUBLIC_IP")
    region1:
      region: $(yaml_quote "$AWS_REGION1")
      network_acl_id: $(yaml_quote "$REGION1_NACL_ID")
      deny_inbound_rule_number: 90
      deny_outbound_rule_number: 91
    region2:
      region: $(yaml_quote "$AWS_REGION2")
      network_acl_id: $(yaml_quote "$REGION2_NACL_ID")
EOF

echo ""
echo -e "${GREEN}✅ Local runtime config generated${NC}"
echo "  Config path: $RUNTIME_CONFIG"
echo "  Region 1 API target: $REGION1_API_TARGET:443"
echo "  Region 2 API target: $REGION2_API_TARGET:443"
echo "  Region 1 DB target: $REGION1_DB_TARGET:$DATABASE_PORT"
echo "  Region 2 DB target: $REGION2_DB_TARGET:$DATABASE_PORT"
echo ""
echo -e "${YELLOW}ℹ️ Public display endpoints:${NC}"
echo "  Region 1 API: $REGION1_API_DISPLAY"
echo "  Region 2 API: $REGION2_API_DISPLAY"
echo "  Region 1 DB: $REGION1_DB_DISPLAY"
echo "  Region 2 DB: $REGION2_DB_DISPLAY"
echo ""

if [ "$GENERATE_ONLY" = "true" ]; then
    echo -e "${GREEN}✅ Generated config only. Exiting without starting Flask.${NC}"
    cat "$RUNTIME_CONFIG"
    exit 0
fi

echo -e "${BLUE}🚀 Starting local UI at http://${APP_HOST}:${APP_PORT}${NC}"
echo ""

export CONFIG_PATH="$RUNTIME_CONFIG"
export APP_HOST
export APP_PORT

cd "$SCRIPT_DIR"
python3 "$SCRIPT_DIR/app/app.py"
