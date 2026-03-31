#!/bin/bash
#==============================================================================
# REDIS ENTERPRISE MONITORING UI + FAILOVER DEMO DEPLOYMENT SCRIPT
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
ENV_CONFIG="$SCRIPT_DIR/../config.env"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

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

detect_monitoring_secret() {
    local context="$1"
    local rec_name="$2"
    local prefixed="redis-enterprise-$rec_name"

    if kubectl get secret "$rec_name" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1; then
        echo "$rec_name"
        return
    fi

    if kubectl get secret "$prefixed" -n "$NAMESPACE" --context "$context" >/dev/null 2>&1; then
        echo "$prefixed"
        return
    fi

    local discovered
    discovered="$(kubectl get secret -n "$NAMESPACE" --context "$context" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | rg "${rec_name}$" | head -1 || true)"
    [ -n "$discovered" ] || fail "Could not find an API credential secret for $rec_name in context $context."
    echo "$discovered"
}

detect_remote_db_endpoint() {
    local db_name="$1"
    local context="$2"
    local endpoint_ip

    endpoint_ip="$(kubectl get endpoints "$db_name" -n "$NAMESPACE" --context "$context" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | head -1 || true)"
    [ -n "$endpoint_ip" ] || fail "Could not determine a remote database endpoint IP for $db_name in context $context."
    echo "$endpoint_ip"
}

echo ""
echo "=========================================================================="
echo "  Redis Monitoring UI + Failover Demo Deployment"
echo "=========================================================================="
echo ""

require_command aws
require_command kubectl
require_command python3

[ -f "$ENV_CONFIG" ] || fail "config.env not found. Run terraform apply first."
[ -f "$CONFIG_FILE" ] || fail "config.yaml not found."

echo -e "${BLUE}📋 Loading configuration from config.env...${NC}"
source "$ENV_CONFIG"

DEPLOYMENT_REGION="$(read_cfg 'deployment_region' 'region1')"
REFRESH_INTERVAL="$(read_cfg 'refresh_interval' '5')"
DATABASE_OVERRIDE="$(read_cfg 'database_name' '')"
DATABASE_PORT_OVERRIDE="$(read_cfg 'database_port' '0')"

if [ "$DEPLOYMENT_REGION" = "region1" ]; then
    DEPLOY_CONTEXT="$REGION1_CONTEXT"
elif [ "$DEPLOYMENT_REGION" = "region2" ]; then
    DEPLOY_CONTEXT="$REGION2_CONTEXT"
else
    fail "deployment_region must be region1 or region2."
fi

echo -e "${BLUE}🔧 Configuring kubectl contexts...${NC}"
aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null

kubectl get namespace "$NAMESPACE" --context "$DEPLOY_CONTEXT" >/dev/null 2>&1 || fail "Namespace $NAMESPACE not found in context $DEPLOY_CONTEXT."

echo -e "${BLUE}🔍 Auto-detecting database...${NC}"
if [ -n "$DATABASE_OVERRIDE" ]; then
    DATABASE_NAME="$DATABASE_OVERRIDE"
else
    DATABASE_NAME="$(kubectl get reaadb -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$DATABASE_NAME" ] || DATABASE_NAME="$CRDB_NAME"
fi
[ -n "$DATABASE_NAME" ] || fail "Could not determine the database name."
echo -e "${GREEN}✅ Database: $DATABASE_NAME${NC}"

echo -e "${BLUE}🔍 Auto-detecting database port...${NC}"
if [ "$DATABASE_PORT_OVERRIDE" != "0" ]; then
    DATABASE_PORT="$DATABASE_PORT_OVERRIDE"
else
    DATABASE_PORT="$(kubectl get svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    [ -n "$DATABASE_PORT" ] || DATABASE_PORT="$(kubectl get svc "$DATABASE_NAME" -n "$NAMESPACE" --context "$REGION2_CONTEXT" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
fi
[ -n "$DATABASE_PORT" ] || fail "Could not determine the database port."
echo -e "${GREEN}✅ Database port: $DATABASE_PORT${NC}"

REGION1_SECRET="$(detect_monitoring_secret "$DEPLOY_CONTEXT" "$REGION1_REC_NAME")"
REGION2_SECRET="$(detect_monitoring_secret "$DEPLOY_CONTEXT" "$REGION2_REC_NAME")"
DB_SECRET_NAME=""
if kubectl get secret "${DATABASE_NAME}-password" -n "$NAMESPACE" --context "$DEPLOY_CONTEXT" >/dev/null 2>&1; then
    DB_SECRET_NAME="${DATABASE_NAME}-password"
fi

REGION1_DB_ENDPOINT="${DATABASE_NAME}.${NAMESPACE}.svc.cluster.local"
REGION2_DB_ENDPOINT="$(detect_remote_db_endpoint "$DATABASE_NAME" "$REGION2_CONTEXT")"
REGION1_API_ENDPOINT="${REGION1_API_FQDN:-api.region1.${INGRESS_DOMAIN}}"
REGION2_API_ENDPOINT="${REGION2_API_FQDN:-api.region2.${INGRESS_DOMAIN}}"
REGION1_API_PORT="443"
REGION2_API_PORT="443"

PREFERRED_REGION="$(read_cfg 'failover.preferred_region' 'region1')"
FAIL_WINDOW="$(read_cfg 'failover.failures_detection_window_seconds' '2')"
MIN_FAILURES="$(read_cfg 'failover.min_num_failures' '2')"
FAIL_RATE="$(read_cfg 'failover.failure_rate_threshold' '0.5')"
HEALTH_INTERVAL="$(read_cfg 'failover.health_check_interval_seconds' '5')"
HEALTH_PROBES="$(read_cfg 'failover.health_check_probes' '3')"
HEALTH_PROBE_DELAY="$(read_cfg 'failover.health_check_probe_delay_seconds' '0.5')"
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
IMAGE_REPOSITORY="$(read_cfg 'image.repository' 'python')"
IMAGE_TAG="$(read_cfg 'image.tag' '3.11-slim')"
IMAGE_PULL_POLICY="$(read_cfg 'image.pullPolicy' 'IfNotPresent')"
CPU_REQUEST="$(read_cfg 'resources.requests.cpu' '250m')"
MEMORY_REQUEST="$(read_cfg 'resources.requests.memory' '256Mi')"
CPU_LIMIT="$(read_cfg 'resources.limits.cpu' '500m')"
MEMORY_LIMIT="$(read_cfg 'resources.limits.memory' '512Mi')"

echo ""
echo -e "${BLUE}📦 Deployment Configuration:${NC}"
echo "  Context: $DEPLOY_CONTEXT"
echo "  Namespace: $NAMESPACE"
echo "  Preferred Redis region: $PREFERRED_REGION"
echo "  Region 1 Redis endpoint: $REGION1_DB_ENDPOINT:$DATABASE_PORT (in-cluster service)"
echo "  Region 2 Redis endpoint: $REGION2_DB_ENDPOINT:$DATABASE_PORT (remote backend IP)"
echo "  Region 1 API secret: $REGION1_SECRET"
echo "  Region 2 API secret: $REGION2_SECRET"
if [ -n "$DB_SECRET_NAME" ]; then
    echo "  Database password secret: $DB_SECRET_NAME"
else
    echo "  Database password secret: <none detected>"
fi
echo ""

AUTO_CONFIG="$TMP_DIR/config.yaml"
cat > "$AUTO_CONFIG" <<EOF
deployment_region: $DEPLOYMENT_REGION
namespace: $NAMESPACE
refresh_interval: $REFRESH_INTERVAL
database_name: $DATABASE_NAME

regions:
  region1:
    name: $AWS_REGION1
    api_endpoint: $REGION1_API_ENDPOINT
    api_port: $REGION1_API_PORT
    monitoring_secret_name: $REGION1_SECRET
    redis_endpoint: $REGION1_DB_ENDPOINT
    redis_port: $DATABASE_PORT
    redis_weight: $( [ "$PREFERRED_REGION" = "region1" ] && echo "1.0" || echo "0.5" )
    health_check_url: https://$REGION1_API_ENDPOINT
  region2:
    name: $AWS_REGION2
    api_endpoint: $REGION2_API_ENDPOINT
    api_port: $REGION2_API_PORT
    monitoring_secret_name: $REGION2_SECRET
    redis_endpoint: $REGION2_DB_ENDPOINT
    redis_port: $DATABASE_PORT
    redis_weight: $( [ "$PREFERRED_REGION" = "region2" ] && echo "1.0" || echo "0.5" )
    health_check_url: https://$REGION2_API_ENDPOINT

redis:
  port: $DATABASE_PORT
  tls: true
  verify_tls: false
  database_secret_name: "$DB_SECRET_NAME"

failover:
  preferred_region: $PREFERRED_REGION
  failures_detection_window_seconds: $FAIL_WINDOW
  min_num_failures: $MIN_FAILURES
  failure_rate_threshold: $FAIL_RATE
  health_check_interval_seconds: $HEALTH_INTERVAL
  health_check_probes: $HEALTH_PROBES
  health_check_probe_delay_seconds: $HEALTH_PROBE_DELAY
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
EOF

AUTO_DEPLOYMENT="$TMP_DIR/deployment.yaml"
cat > "$AUTO_DEPLOYMENT" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-monitoring-ui
  namespace: $NAMESPACE
  labels:
    app: redis-monitoring-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-monitoring-ui
  template:
    metadata:
      labels:
        app: redis-monitoring-ui
    spec:
      serviceAccountName: redis-monitoring-ui
      initContainers:
        - name: install-dependencies
          image: ${IMAGE_REPOSITORY}:${IMAGE_TAG}
          imagePullPolicy: $IMAGE_PULL_POLICY
          command:
            - /bin/sh
            - -c
            - |
              pip install --no-cache-dir -r /app/requirements.txt
              cp -r /usr/local/lib/python3.11/site-packages/* /app/packages/
          volumeMounts:
            - name: app-code
              mountPath: /app/app.py
              subPath: app.py
            - name: app-code
              mountPath: /app/requirements.txt
              subPath: requirements.txt
            - name: packages
              mountPath: /app/packages
      containers:
        - name: flask-app
          image: ${IMAGE_REPOSITORY}:${IMAGE_TAG}
          imagePullPolicy: $IMAGE_PULL_POLICY
          ports:
            - containerPort: 5000
              name: http
          env:
            - name: PYTHONPATH
              value: /app/packages
            - name: CONFIG_PATH
              value: /app/config/config.yaml
          command:
            - python
            - /app/app.py
          resources:
            requests:
              cpu: $CPU_REQUEST
              memory: $MEMORY_REQUEST
            limits:
              cpu: $CPU_LIMIT
              memory: $MEMORY_LIMIT
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: app-code
              mountPath: /app/app.py
              subPath: app.py
            - name: app-code
              mountPath: /app/requirements.txt
              subPath: requirements.txt
            - name: templates
              mountPath: /app/templates/index.html
              subPath: index.html
            - name: config
              mountPath: /app/config/config.yaml
              subPath: config.yaml
            - name: packages
              mountPath: /app/packages
      volumes:
        - name: app-code
          configMap:
            name: redis-monitoring-ui-code
        - name: templates
          configMap:
            name: redis-monitoring-ui-templates
        - name: config
          configMap:
            name: redis-monitoring-ui-config
        - name: packages
          emptyDir: {}
EOF

echo -e "${BLUE}📦 Creating ConfigMaps...${NC}"
kubectl create configmap redis-monitoring-ui-code \
    --from-file=app.py="$SCRIPT_DIR/app/app.py" \
    --from-file=requirements.txt="$SCRIPT_DIR/requirements.txt" \
    --namespace="$NAMESPACE" \
    --context="$DEPLOY_CONTEXT" \
    --dry-run=client -o yaml | kubectl apply --context="$DEPLOY_CONTEXT" -f -

kubectl create configmap redis-monitoring-ui-templates \
    --from-file=index.html="$SCRIPT_DIR/app/templates/index.html" \
    --namespace="$NAMESPACE" \
    --context="$DEPLOY_CONTEXT" \
    --dry-run=client -o yaml | kubectl apply --context="$DEPLOY_CONTEXT" -f -

kubectl create configmap redis-monitoring-ui-config \
    --from-file=config.yaml="$AUTO_CONFIG" \
    --namespace="$NAMESPACE" \
    --context="$DEPLOY_CONTEXT" \
    --dry-run=client -o yaml | kubectl apply --context="$DEPLOY_CONTEXT" -f -

echo -e "${BLUE}🔐 Deploying RBAC...${NC}"
kubectl apply -f "$SCRIPT_DIR/k8s/rbac.yaml" --context="$DEPLOY_CONTEXT"

echo -e "${BLUE}🌐 Deploying Service...${NC}"
kubectl apply -f "$SCRIPT_DIR/k8s/service.yaml" --context="$DEPLOY_CONTEXT"

echo -e "${BLUE}🚀 Deploying application...${NC}"
kubectl apply -f "$AUTO_DEPLOYMENT" --context="$DEPLOY_CONTEXT"

echo -e "${YELLOW}⏳ Waiting for deployment to be ready...${NC}"
kubectl rollout status deployment/redis-monitoring-ui -n "$NAMESPACE" --context="$DEPLOY_CONTEXT" --timeout=180s

echo ""
echo "=========================================================================="
echo -e "${GREEN}✅ Redis Monitoring UI + Failover Demo Deployed${NC}"
echo "=========================================================================="
echo ""
echo "Access the UI:"
echo "  kubectl port-forward -n $NAMESPACE svc/redis-monitoring-ui 8080:5000 --context $DEPLOY_CONTEXT"
echo ""
echo "Then open: http://localhost:8080"
echo ""
