#!/bin/bash

#==============================================================================
# ACTIVE-ACTIVE CRDB DEPLOYMENT SCRIPT
#==============================================================================
# This script deploys a Redis Enterprise Active-Active database (CRDB)
# after both Redis Enterprise clusters are licensed and reachable.
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.env"
TMP_DIR="$(mktemp -d)"
readonly SCRIPT_DIR CONFIG_FILE TMP_DIR

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log_section() {
    echo ""
    echo "=========================================================================="
    echo "  $1"
    echo "=========================================================================="
    echo ""
}

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}$1${NC}"
}

success() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

json_has_truthy_error() {
    local file="$1"

    python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

if isinstance(data, dict):
    if data.get("expired") is True:
        sys.exit(0)
    for key in ("error", "errors", "status"):
        value = data.get(key)
        if isinstance(value, str) and any(token in value.lower() for token in ("error", "invalid", "unlicensed", "expired", "failed")):
            sys.exit(0)
        if isinstance(value, list) and value:
            sys.exit(0)

sys.exit(1)
PY
}

load_config() {
    [ -f "$CONFIG_FILE" ] || fail "config.env not found at $CONFIG_FILE. Run terraform apply first."

    info "📋 Loading configuration..."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    REQUIRED_VARS=(
        PROJECT_PREFIX
        AWS_PROFILE
        AWS_REGION1
        AWS_REGION2
        REGION1_CLUSTER_NAME
        REGION2_CLUSTER_NAME
        REGION1_REC_NAME
        REGION2_REC_NAME
        REGION1_CONTEXT
        REGION2_CONTEXT
        NAMESPACE
        CRDB_NAME
        CRDB_MEMORY
        CRDB_SHARDS
        CRDB_REPLICATION
        CRDB_PERSISTENCE
        CRDB_EVICTION_POLICY
        REGION1_API_FQDN
        REGION2_API_FQDN
    )

    for var_name in "${REQUIRED_VARS[@]}"; do
        [ -n "${!var_name:-}" ] || fail "Required variable $var_name is not set in config.env"
    done

    [[ "$CRDB_SHARDS" =~ ^[0-9]+$ ]] || fail "CRDB_SHARDS must be an integer. Current value: $CRDB_SHARDS"
    [ "$CRDB_SHARDS" -gt 0 ] || fail "CRDB_SHARDS must be greater than zero."

    success "✅ Configuration loaded"
}

configure_kubectl_contexts() {
    info "🔧 Configuring kubectl contexts..."
    aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
    aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
    success "✅ Kubectl contexts configured"
}

resolve_host() {
    local host="$1"

    if command -v dig >/dev/null 2>&1; then
        dig +short "$host" | grep -q .
        return
    fi

    if command -v host >/dev/null 2>&1; then
        host "$host" >/dev/null 2>&1
        return
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" >/dev/null 2>&1
        return
    fi

    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1
        return
    fi

    fail "No DNS lookup tool found (dig, host, nslookup, or getent)."
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

    aws route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --profile "$AWS_PROFILE" \
        --query "ResourceRecordSets[?Name == '${fqdn}.'] | [0].ResourceRecords[0].Value" \
        --output text 2>/dev/null
}

kubectl_jsonpath() {
    local context="$1"
    local kind="$2"
    local name="$3"
    local jsonpath="$4"

    kubectl get "$kind" "$name" -n "$NAMESPACE" --context "$context" -o "jsonpath=$jsonpath" 2>/dev/null || true
}

wait_for_rec_running() {
    local context="$1"
    local rec_name="$2"
    local region_label="$3"
    local timeout=900
    local elapsed=0
    local status=""

    info "🔍 Waiting for $region_label REC ($rec_name) to reach Running..."

    while [ "$elapsed" -lt "$timeout" ]; do
        status="$(kubectl_jsonpath "$context" rec "$rec_name" '{.status.state}')"
        if [ "$status" = "Running" ]; then
            success "✅ $region_label REC is Running"
            return
        fi

        echo "  $region_label status: ${status:-pending} (${elapsed}s elapsed)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    fail "$region_label REC $rec_name did not reach Running within $timeout seconds."
}

get_rec_credentials() {
    local context="$1"
    local rec_name="$2"
    local prefix="$3"

    local user pass
    user="$(kubectl get secret "$rec_name" -n "$NAMESPACE" --context "$context" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
    pass="$(kubectl get secret "$rec_name" -n "$NAMESPACE" --context "$context" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

    [ -n "$user" ] || fail "Could not read REC username from secret $rec_name in context $context."
    [ -n "$pass" ] || fail "Could not read REC password from secret $rec_name in context $context."

    printf -v "${prefix}_USER" '%s' "$user"
    printf -v "${prefix}_PASS" '%s' "$pass"
}

check_rerc_ready() {
    local context="$1"
    local rerc_name="$2"
    local label="$3"
    local status

    kubectl get rerc "$rerc_name" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1 || fail "$label RERC $rerc_name does not exist. Run terraform apply first."
    status="$(kubectl_jsonpath "$context" rerc "$rerc_name" '{.status.status}')"

    case "$status" in
        Ready|ready|Running|running|Active|active)
            success "✅ $label RERC $rerc_name is $status"
            ;;
        *)
            fail "$label RERC $rerc_name is not ready. Current status: ${status:-unknown}"
            ;;
    esac
}

try_api_request() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local path="$4"
    local response_file="$5"
    local connect_target="${6:-}"
    local endpoints=(
        "https://${host}${path}"
        "https://${host}:9443${path}"
    )

    local connect_args=()
    if [ -n "$connect_target" ]; then
        connect_args=(
            --connect-to "${host}:443:${connect_target}:443"
            --connect-to "${host}:9443:${connect_target}:9443"
        )
    fi

    local endpoint
    for endpoint in "${endpoints[@]}"; do
        if curl -ksSfu "$user:$pass" "${connect_args[@]}" "$endpoint" -o "$response_file" --connect-timeout 10 --max-time 30; then
            if grep -qiE 'html|not found|404 page' "$response_file"; then
                continue
            fi
            return 0
        fi
    done

    return 1
}

preflight_cluster_api() {
    local cluster_label="$1"
    local api_fqdn="$2"
    local user="$3"
    local pass="$4"
    local requested_shards="$5"
    local license_payload="$TMP_DIR/${cluster_label}-license.json"
    local cluster_payload="$TMP_DIR/${cluster_label}-cluster.json"
    local route53_zone_id=""
    local route53_target=""
    local dns_resolved=false

    info "🌐 Verifying DNS for $cluster_label API endpoint ($api_fqdn)..."
    if resolve_host "$api_fqdn"; then
        dns_resolved=true
        success "✅ DNS resolves for $cluster_label API endpoint"
    else
        route53_zone_id="$(get_route53_zone_id)"
        [ -n "$route53_zone_id" ] || fail "DNS resolution failed for $cluster_label API endpoint $api_fqdn and Route53 zone lookup for $INGRESS_DOMAIN also failed."

        route53_target="$(get_route53_record_target "$api_fqdn" "$route53_zone_id")"
        [ -n "$route53_target" ] && [ "$route53_target" != "None" ] || fail "DNS resolution failed for $cluster_label API endpoint $api_fqdn and no Route53 record target was found."

        warn "⚠️ Local DNS did not resolve $api_fqdn. Route53 record exists in hosted zone $route53_zone_id and points to $route53_target."
        warn "⚠️ Continuing with API checks by connecting through the Route53 CNAME target."
    fi

    info "🔐 Probing $cluster_label API for license status..."
    try_api_request "$api_fqdn" "$user" "$pass" "/v1/license" "$license_payload" "$route53_target" || fail "Could not query the $cluster_label license API. Verify ingress, DNS/Route53, credentials, and that the REC is licensed."

    if json_has_truthy_error "$license_payload"; then
        fail "$cluster_label license API indicates the cluster is not licensed and healthy."
    fi

    info "📊 Probing $cluster_label API for cluster readiness..."
    try_api_request "$api_fqdn" "$user" "$pass" "/v1/cluster" "$cluster_payload" "$route53_target" || fail "Could not query the $cluster_label cluster API after the license check."

    if ! grep -qiE 'node|cluster|uid|name' "$cluster_payload"; then
        fail "$cluster_label cluster API response was not recognized. Refusing to create REAADB without a successful cluster readiness probe."
    fi

    if json_has_truthy_error "$cluster_payload"; then
        fail "$cluster_label cluster API reported an unhealthy state."
    fi

    if [ "$requested_shards" -gt 4 ]; then
        warn "⚠️ Requested shard count is $requested_shards. Capacity validation is best-effort; API and license preflight succeeded."
    fi

    success "✅ $cluster_label API preflight passed"
}

write_secret_manifest() {
    local path="$1"
    local secret_name="$2"
    local user="$3"
    local pass="$4"

    cat > "$path" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  username: "${user}"
  password: "${pass}"
EOF
}

ensure_remote_credentials() {
    local region1_local="$TMP_DIR/region1-local-secret.yaml"
    local region1_remote="$TMP_DIR/region1-remote-secret.yaml"
    local region2_local="$TMP_DIR/region2-local-secret.yaml"
    local region2_remote="$TMP_DIR/region2-remote-secret.yaml"

    info "🔐 Applying idempotent RERC credential secrets..."

    write_secret_manifest "$region1_local" "redis-enterprise-${REGION1_REC_NAME}" "$REC1_USER" "$REC1_PASS"
    write_secret_manifest "$region1_remote" "redis-enterprise-${REGION2_REC_NAME}" "$REC2_USER" "$REC2_PASS"
    write_secret_manifest "$region2_local" "redis-enterprise-${REGION2_REC_NAME}" "$REC2_USER" "$REC2_PASS"
    write_secret_manifest "$region2_remote" "redis-enterprise-${REGION1_REC_NAME}" "$REC1_USER" "$REC1_PASS"

    kubectl apply -f "$region1_local" --context "$REGION1_CONTEXT" >/dev/null
    kubectl apply -f "$region1_remote" --context "$REGION1_CONTEXT" >/dev/null
    kubectl apply -f "$region2_local" --context "$REGION2_CONTEXT" >/dev/null
    kubectl apply -f "$region2_remote" --context "$REGION2_CONTEXT" >/dev/null

    success "✅ RERC credential secrets applied"
}

generate_reaadb_manifest() {
    REAADB_MANIFEST="$TMP_DIR/reaadb.yaml"

    cat > "$REAADB_MANIFEST" <<EOF
apiVersion: app.redislabs.com/v1alpha1
kind: RedisEnterpriseActiveActiveDatabase
metadata:
  name: ${CRDB_NAME}
  namespace: ${NAMESPACE}
spec:
  participatingClusters:
    - name: ${REGION1_REC_NAME}
    - name: ${REGION2_REC_NAME}
  globalConfigurations:
    evictionPolicy: ${CRDB_EVICTION_POLICY}
    memorySize: ${CRDB_MEMORY}
    ossCluster: false
    persistence: ${CRDB_PERSISTENCE}
    replication: ${CRDB_REPLICATION}
    shardCount: ${CRDB_SHARDS}
    type: redis
EOF

    success "✅ Generated ephemeral REAADB manifest at $REAADB_MANIFEST"
}

apply_reaadb() {
    local existing_status
    existing_status="$(kubectl get reaadb "$CRDB_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.status.status}' 2>/dev/null || true)"

    if [ -n "$existing_status" ]; then
        warn "⚠️ REAADB $CRDB_NAME already exists with status ${existing_status}. Re-applying manifest idempotently."
    fi

    kubectl apply -f "$REAADB_MANIFEST" --context "$REGION1_CONTEXT" >/dev/null
    success "✅ REAADB manifest applied"
}

wait_for_reaadb() {
    local timeout=600
    local elapsed=0
    local status=""

    info "⏳ Waiting for REAADB $CRDB_NAME to become active..."

    while [ "$elapsed" -lt "$timeout" ]; do
        status="$(kubectl get reaadb "$CRDB_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.status.status}' 2>/dev/null || true)"

        case "$status" in
            active|Active)
                success "✅ REAADB is active"
                return
                ;;
            creation-failed|CreationFailed|failed|Failed)
                kubectl get reaadb "$CRDB_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o yaml
                fail "REAADB creation failed."
                ;;
        esac

        echo "  Status: ${status:-pending} (${elapsed}s elapsed)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    fail "Timed out waiting for REAADB $CRDB_NAME to become active."
}

main() {
    log_section "Active-Active CRDB Deployment"

    require_command aws
    require_command kubectl
    require_command curl
    require_command mktemp

    load_config

    echo "CRDB Configuration:"
    echo "  Name: $CRDB_NAME"
    echo "  Memory: $CRDB_MEMORY"
    echo "  Shards: $CRDB_SHARDS"
    echo "  Replication: $CRDB_REPLICATION"
    echo "  Persistence: $CRDB_PERSISTENCE"
    echo "  Eviction Policy: $CRDB_EVICTION_POLICY"
    echo ""
    echo "Manual checkpoint:"
    echo "  Upload the license in both Redis Enterprise admin UIs before continuing."
    echo ""

    configure_kubectl_contexts
    wait_for_rec_running "$REGION1_CONTEXT" "$REGION1_REC_NAME" "Region 1"
    wait_for_rec_running "$REGION2_CONTEXT" "$REGION2_REC_NAME" "Region 2"

    get_rec_credentials "$REGION1_CONTEXT" "$REGION1_REC_NAME" REC1
    get_rec_credentials "$REGION2_CONTEXT" "$REGION2_REC_NAME" REC2

    ensure_remote_credentials

    info "🔗 Verifying Remote Cluster resources..."
    check_rerc_ready "$REGION1_CONTEXT" "$REGION1_REC_NAME" "Region 1 local"
    check_rerc_ready "$REGION1_CONTEXT" "$REGION2_REC_NAME" "Region 1 remote"
    check_rerc_ready "$REGION2_CONTEXT" "$REGION2_REC_NAME" "Region 2 local"
    check_rerc_ready "$REGION2_CONTEXT" "$REGION1_REC_NAME" "Region 2 remote"

    preflight_cluster_api "region1" "$REGION1_API_FQDN" "$REC1_USER" "$REC1_PASS" "$CRDB_SHARDS"
    preflight_cluster_api "region2" "$REGION2_API_FQDN" "$REC2_USER" "$REC2_PASS" "$CRDB_SHARDS"

    generate_reaadb_manifest
    apply_reaadb
    wait_for_reaadb

    echo ""
    echo "Verification Commands:"
    echo "  kubectl get reaadb $CRDB_NAME -n $NAMESPACE --context $REGION1_CONTEXT"
    echo "  kubectl get reaadb $CRDB_NAME -n $NAMESPACE --context $REGION2_CONTEXT"
    echo "  kubectl get reaadb $CRDB_NAME -n $NAMESPACE --context $REGION1_CONTEXT -o yaml"
    echo ""
    success "✅ Active-Active CRDB deployed successfully"
}

main "$@"
