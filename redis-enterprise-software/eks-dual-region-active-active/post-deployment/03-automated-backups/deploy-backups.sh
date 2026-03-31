#!/bin/bash

#==============================================================================
# AUTOMATED BACKUPS DEPLOYMENT SCRIPT
#==============================================================================
# This script configures periodic S3 backups through the Redis Enterprise REST
# API for the local CRDB database object in each region.
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

load_config() {
    [ -f "$CONFIG_FILE" ] || fail "config.env not found at $CONFIG_FILE. Run terraform apply first."

    info "📋 Loading configuration..."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    REQUIRED_VARS=(
        AWS_PROFILE
        AWS_REGION1
        AWS_REGION2
        REGION1_CLUSTER_NAME
        REGION2_CLUSTER_NAME
        REGION1_REC_NAME
        REGION2_REC_NAME
        REGION1_CONTEXT
        REGION2_CONTEXT
        REGION1_API_FQDN
        REGION2_API_FQDN
        INGRESS_DOMAIN
        NAMESPACE
        CRDB_NAME
        BACKUP_INTERVAL
    )

    for var_name in "${REQUIRED_VARS[@]}"; do
        [ -n "${!var_name:-}" ] || fail "Required variable $var_name is not set in config.env"
    done

    normalize_backup_config

    [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "BACKUP_RETENTION_DAYS must be an integer."
    [ "$BACKUP_RETENTION_DAYS" -ge 0 ] || fail "BACKUP_RETENTION_DAYS must be zero or greater."

    success "✅ Configuration loaded"
}

normalize_backup_config() {
    if [ -z "${S3_BACKUP_BUCKET_REGION1:-}" ]; then
        S3_BACKUP_BUCKET_REGION1="${PROJECT_PREFIX}-redis-backups-${AWS_REGION1}"
    fi

    if [ -z "${S3_BACKUP_BUCKET_REGION2:-}" ]; then
        S3_BACKUP_BUCKET_REGION2="${PROJECT_PREFIX}-redis-backups-${AWS_REGION2}"
    fi

    if [ -z "${S3_BACKUP_PREFIX:-}" ]; then
        S3_BACKUP_PREFIX="backup"
    fi

    if [ -z "${BACKUP_RETENTION_DAYS:-}" ]; then
        BACKUP_RETENTION_DAYS="${BACKUP_RETENTION:-7}"
    fi
}

backup_interval_to_seconds() {
    python3 - "$BACKUP_INTERVAL" <<'PY'
import re
import sys

value = sys.argv[1].strip()
pattern = re.fullmatch(r"(?i)(\d+)([smhd])", value)
if not pattern:
    print("")
    sys.exit(0)

amount = int(pattern.group(1))
unit = pattern.group(2).lower()
scale = {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
print(amount * scale)
PY
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

get_api_connect_target() {
    local host="$1"
    local cluster_label="$2"
    local zone_id=""
    local route53_target=""

    if resolve_host "$host"; then
        printf '%s\n' ""
        return
    fi

    zone_id="$(get_route53_zone_id)"
    [ -n "$zone_id" ] || fail "DNS resolution failed for $cluster_label API endpoint $host and Route53 zone lookup also failed."

    route53_target="$(get_route53_record_target "$host" "$zone_id")"
    [ -n "$route53_target" ] && [ "$route53_target" != "None" ] || fail "No Route53 record target found for $cluster_label API endpoint $host."

    echo -e "${YELLOW}⚠️ Local DNS did not resolve $host. Using Route53 target $route53_target for API requests.${NC}" >&2
    printf '%s\n' "$route53_target"
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

load_aws_backup_credentials() {
    info "🔐 Loading AWS backup credentials from profile $AWS_PROFILE..."

    AWS_ACCESS_KEY_ID_VALUE="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE" || true)"
    AWS_SECRET_ACCESS_KEY_VALUE="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE" || true)"
    AWS_SESSION_TOKEN_VALUE="$(aws configure get aws_session_token --profile "$AWS_PROFILE" || true)"

    [ -n "$AWS_ACCESS_KEY_ID_VALUE" ] || fail "No aws_access_key_id found for profile $AWS_PROFILE."
    [ -n "$AWS_SECRET_ACCESS_KEY_VALUE" ] || fail "No aws_secret_access_key found for profile $AWS_PROFILE."

    if [ -n "$AWS_SESSION_TOKEN_VALUE" ]; then
        fail "Profile $AWS_PROFILE uses an AWS session token. Redis Enterprise backup_location for S3 only documents Access Key ID and Secret Access Key, so use a profile backed by long-lived keys for this workflow."
    fi

    success "✅ AWS backup credentials loaded"
}

write_lifecycle_policy() {
    local path="$1"

    cat > "$path" <<EOF
{
  "Rules": [
    {
      "ID": "expire-redis-backups",
      "Status": "Enabled",
      "Filter": {
        "Prefix": ""
      },
      "Expiration": {
        "Days": $BACKUP_RETENTION_DAYS
      }
    }
  ]
}
EOF
}

ensure_bucket() {
    local bucket="$1"
    local aws_region="$2"
    local label="$3"
    local lifecycle_file="$TMP_DIR/${label}-lifecycle.json"

    info "🪣 Ensuring backup bucket exists for $label: $bucket"
    if ! aws s3api head-bucket --bucket "$bucket" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        warn "⚠️ Bucket $bucket does not exist. Creating it in $aws_region."
        if [ "$aws_region" = "us-east-1" ]; then
            aws s3api create-bucket --bucket "$bucket" --region "$aws_region" --profile "$AWS_PROFILE" >/dev/null
        else
            aws s3api create-bucket \
                --bucket "$bucket" \
                --region "$aws_region" \
                --create-bucket-configuration "LocationConstraint=$aws_region" \
                --profile "$AWS_PROFILE" >/dev/null
        fi
    fi

    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
        --profile "$AWS_PROFILE" >/dev/null

    aws s3api put-bucket-encryption \
        --bucket "$bucket" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
        --profile "$AWS_PROFILE" >/dev/null

    write_lifecycle_policy "$lifecycle_file"
    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket" \
        --lifecycle-configuration "file://$lifecycle_file" \
        --profile "$AWS_PROFILE" >/dev/null

    success "✅ Bucket ready for $label"
}

api_request() {
    local method="$1"
    local host="$2"
    local user="$3"
    local pass="$4"
    local path="$5"
    local response_file="$6"
    local connect_target="${7:-}"
    local body_file="${8:-}"
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

    local endpoint http_code
    for endpoint in "${endpoints[@]}"; do
        local curl_args=(
            -ksSu "$user:$pass"
            "${connect_args[@]}"
            -o "$response_file"
            -w "%{http_code}"
            --connect-timeout 10
            --max-time 60
            -X "$method"
            -H "Accept: application/json"
        )

        if [ -n "$body_file" ]; then
            curl_args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
        fi

        http_code="$(curl "${curl_args[@]}" "$endpoint" || true)"
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            if grep -qiE 'html|not found|404 page' "$response_file"; then
                continue
            fi
            return 0
        fi
    done

    return 1
}

lookup_bdb_uid() {
    local response_file="$1"
    local db_name="$2"

    python3 - "$response_file" "$db_name" <<'PY'
import json
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

for item in data:
    if item.get("name") == name:
        print(item.get("uid", ""))
        break
else:
    print("")
PY
}

verify_backup_response() {
    local response_file="$1"
    local bucket="$2"
    local subdir="$3"
    local interval_seconds="$4"
    local retention_days="$5"

    python3 - "$response_file" "$bucket" "$subdir" "$interval_seconds" "$retention_days" <<'PY'
import json
import sys

path, bucket, subdir, interval_seconds, retention_days = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

backup_location = data.get("backup_location") or {}
if not data.get("backup"):
    sys.exit(1)
if str(data.get("backup_interval")) != str(interval_seconds):
    sys.exit(1)
if str(data.get("backup_history")) != str(retention_days):
    sys.exit(1)
if backup_location.get("bucket_name") != bucket:
    sys.exit(1)
if backup_location.get("subdir", "") != subdir:
    sys.exit(1)
PY
}

build_backup_subdir() {
    local region_label="$1"
    local subdir="$CRDB_NAME"

    if [ -n "${S3_BACKUP_PREFIX:-}" ]; then
        subdir="${S3_BACKUP_PREFIX}/${region_label}/${CRDB_NAME}"
    else
        subdir="${region_label}/${CRDB_NAME}"
    fi

    printf '%s\n' "$subdir"
}

write_backup_payload() {
    local path="$1"
    local bucket="$2"
    local region_name="$3"
    local subdir="$4"

    python3 - "$path" "$bucket" "$region_name" "$subdir" "$AWS_ACCESS_KEY_ID_VALUE" "$AWS_SECRET_ACCESS_KEY_VALUE" "$BACKUP_INTERVAL_SECONDS" "$BACKUP_RETENTION_DAYS" <<'PY'
import json
import sys

path, bucket, region_name, subdir, access_key, secret_key, interval_seconds, retention_days = sys.argv[1:]
payload = {
    "backup": True,
    "backup_interval": int(interval_seconds),
    "backup_history": int(retention_days),
    "backup_location": {
        "type": "s3",
        "bucket_name": bucket,
        "region_name": region_name,
        "subdir": subdir,
        "access_key_id": access_key,
        "secret_access_key": secret_key,
    },
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
PY
}

configure_backup_for_region() {
    local region_label="$1"
    local context="$2"
    local rec_name="$3"
    local api_fqdn="$4"
    local api_user="$5"
    local api_pass="$6"
    local aws_region="$7"
    local bucket="$8"
    local connect_target="$9"
    local listing_file="$TMP_DIR/${region_label}-bdbs.json"
    local payload_file="$TMP_DIR/${region_label}-backup-payload.json"
    local response_file="$TMP_DIR/${region_label}-backup-response.json"
    local bdb_uid=""
    local backup_subdir=""

    kubectl get rec "$rec_name" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1 || fail "$region_label REC $rec_name is not accessible."

    info "🔎 Discovering local database object for $CRDB_NAME in $region_label..."
    api_request "GET" "$api_fqdn" "$api_user" "$api_pass" "/v1/bdbs?fields=uid,name,status,crdt,backup,backup_interval,backup_history,backup_location" "$listing_file" "$connect_target" || fail "Could not list databases from the $region_label REC API."

    bdb_uid="$(lookup_bdb_uid "$listing_file" "$CRDB_NAME")"
    [ -n "$bdb_uid" ] || fail "Could not find a local BDB named $CRDB_NAME in $region_label."

    backup_subdir="$(build_backup_subdir "$region_label")"
    write_backup_payload "$payload_file" "$bucket" "$aws_region" "$backup_subdir"

    info "💾 Enabling periodic S3 backups for $region_label BDB uid $bdb_uid..."
    api_request "PUT" "$api_fqdn" "$api_user" "$api_pass" "/v1/bdbs/${bdb_uid}" "$response_file" "$connect_target" "$payload_file" || fail "Backup API update failed for $region_label."

    if ! verify_backup_response "$response_file" "$bucket" "$backup_subdir" "$BACKUP_INTERVAL_SECONDS" "$BACKUP_RETENTION_DAYS"; then
        fail "Backup API response for $region_label did not confirm the expected bucket/subdir."
    fi

    success "✅ Backups configured for $region_label"
    echo "  Database: $CRDB_NAME"
    echo "  S3 Path: s3://$bucket/$backup_subdir"
    echo "  Interval: $BACKUP_INTERVAL ($BACKUP_INTERVAL_SECONDS seconds)"
    echo "  Retention: $BACKUP_RETENTION_DAYS days"
}

main() {
    log_section "Automated Backups Deployment"

    require_command aws
    require_command kubectl
    require_command curl
    require_command python3
    require_command mktemp

    load_config

    BACKUP_INTERVAL_SECONDS="$(backup_interval_to_seconds)"
    [ -n "$BACKUP_INTERVAL_SECONDS" ] || fail "BACKUP_INTERVAL must be a simple duration like 1h, 6h, 12h, or 24h."

    echo "Backup Configuration:"
    echo "  Database: $CRDB_NAME"
    echo "  Region 1 Bucket: $S3_BACKUP_BUCKET_REGION1"
    echo "  Region 2 Bucket: $S3_BACKUP_BUCKET_REGION2"
    echo "  Prefix: ${S3_BACKUP_PREFIX:-<none>}"
    echo "  Interval: $BACKUP_INTERVAL"
    echo "  Retention: $BACKUP_RETENTION_DAYS days"
    echo ""

    configure_kubectl_contexts
    get_rec_credentials "$REGION1_CONTEXT" "$REGION1_REC_NAME" REC1
    get_rec_credentials "$REGION2_CONTEXT" "$REGION2_REC_NAME" REC2
    load_aws_backup_credentials

    ensure_bucket "$S3_BACKUP_BUCKET_REGION1" "$AWS_REGION1" "region1"
    ensure_bucket "$S3_BACKUP_BUCKET_REGION2" "$AWS_REGION2" "region2"

    REGION1_CONNECT_TARGET="$(get_api_connect_target "$REGION1_API_FQDN" "region1")"
    REGION2_CONNECT_TARGET="$(get_api_connect_target "$REGION2_API_FQDN" "region2")"

    configure_backup_for_region "region1" "$REGION1_CONTEXT" "$REGION1_REC_NAME" "$REGION1_API_FQDN" "$REC1_USER" "$REC1_PASS" "$AWS_REGION1" "$S3_BACKUP_BUCKET_REGION1" "$REGION1_CONNECT_TARGET"
    configure_backup_for_region "region2" "$REGION2_CONTEXT" "$REGION2_REC_NAME" "$REGION2_API_FQDN" "$REC2_USER" "$REC2_PASS" "$AWS_REGION2" "$S3_BACKUP_BUCKET_REGION2" "$REGION2_CONNECT_TARGET"

    echo ""
    echo "Verification Commands:"
    echo "  aws s3 ls \"s3://$S3_BACKUP_BUCKET_REGION1/$(build_backup_subdir region1)/\" --profile $AWS_PROFILE"
    echo "  aws s3 ls \"s3://$S3_BACKUP_BUCKET_REGION2/$(build_backup_subdir region2)/\" --profile $AWS_PROFILE"
    echo ""
    success "✅ Automated backups configured through the Redis Enterprise API"
}

main "$@"
