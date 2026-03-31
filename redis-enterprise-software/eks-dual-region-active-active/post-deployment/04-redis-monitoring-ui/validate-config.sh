#!/bin/bash
# Validate that the monitoring UI deploy inputs are available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_CONFIG="$SCRIPT_DIR/../config.env"

[ -f "$ENV_CONFIG" ] || { echo "❌ Missing post-deployment/config.env"; exit 1; }

source "$ENV_CONFIG"

for var in AWS_PROFILE AWS_REGION1 AWS_REGION2 REGION1_CLUSTER_NAME REGION2_CLUSTER_NAME REGION1_CONTEXT REGION2_CONTEXT NAMESPACE CRDB_NAME REGION1_DB_SUFFIX REGION2_DB_SUFFIX; do
    [ -n "${!var:-}" ] || { echo "❌ Missing required config value: $var"; exit 1; }
done

command -v aws >/dev/null 2>&1 || { echo "❌ aws is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 is required"; exit 1; }

echo "✅ Monitoring UI deploy inputs look valid."
