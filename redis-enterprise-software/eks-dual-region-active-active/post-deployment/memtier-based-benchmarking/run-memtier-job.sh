#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./run-memtier-job.sh [options]

Options:
  --manifest <path>        Job manifest to apply. If omitted, prompt interactively.
  --context <name>         kubectl context to use. If omitted, prompt interactively.
  --crdb-name <name>       Redis database service name override.
  --redis-port <port>      Redis service port override.
  --namespace <name>       Kubernetes namespace. Default: redis-enterprise.
  --keep-existing          Do not delete an existing Job with the same name first.
  --help                   Show this help text.

Examples:
  ./run-memtier-job.sh \
    --manifest memtier-load-test-job.yaml \
    --context <kube-context> \
    --crdb-name <crdb-service-name> \
    --redis-port <service-port>

  ./run-memtier-job.sh \
    --manifest memtier-max-throughput-job.yaml \
    --context <kube-context> \
    --crdb-name <crdb-service-name>
EOF
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

prompt_with_default() {
  local prompt="$1"
  local default_value="${2:-}"
  local response=""

  if [ -n "$default_value" ]; then
    read -r -p "$prompt [$default_value]: " response </dev/tty
    printf '%s\n' "${response:-$default_value}"
  else
    read -r -p "$prompt: " response </dev/tty
    printf '%s\n' "$response"
  fi
}

choose_manifest_interactively() {
  local options=(
    "memtier-load-test-job.yaml"
    "memtier-max-throughput-job.yaml"
    "memtier-latency-test-job.yaml"
  )
  local choice=""

  {
    echo "Available memtier jobs:"
    printf '  1. %s - balanced load test for steady throughput and latency\n' "${options[0]}"
    printf '  2. %s - aggressive test to find maximum sustainable throughput\n' "${options[1]}"
    printf '  3. %s - lighter test focused on latency behavior\n' "${options[2]}"
    echo "You can enter 1, 2, 3, or the manifest file name."
  } >&2

  choice="$(prompt_with_default "Select a job" "1")"
  case "$choice" in
    1|"${options[0]}"|"memtier-load-test"|"load")
      printf '%s\n' "${options[0]}"
      ;;
    2|"${options[1]}"|"memtier-max-throughput"|"max-throughput"|"throughput")
      printf '%s\n' "${options[1]}"
      ;;
    3|"${options[2]}"|"memtier-latency-test"|"latency")
      printf '%s\n' "${options[2]}"
      ;;
    *)
      fail "Invalid selection: $choice"
      ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

MANIFEST=""
KUBE_CONTEXT=""
CRDB_NAME=""
REDIS_PORT=""
NAMESPACE="redis-enterprise"
DELETE_EXISTING=true

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      MANIFEST="${2:-}"
      shift 2
      ;;
    --context)
      KUBE_CONTEXT="${2:-}"
      shift 2
      ;;
    --crdb-name)
      CRDB_NAME="${2:-}"
      shift 2
      ;;
    --redis-port)
      REDIS_PORT="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --keep-existing)
      DELETE_EXISTING=false
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command kubectl

if [ -z "$MANIFEST" ]; then
  MANIFEST="$(choose_manifest_interactively)"
fi

if [ ! -f "$MANIFEST" ]; then
  if [ -f "$SCRIPT_DIR/$MANIFEST" ]; then
    MANIFEST="$SCRIPT_DIR/$MANIFEST"
  else
    fail "Manifest not found: $MANIFEST"
  fi
fi

if [ -z "$KUBE_CONTEXT" ]; then
  echo "Kubernetes context is the kubeconfig context name, for example: region1 or region2."
  KUBE_CONTEXT="$(prompt_with_default "Kubernetes context")"
fi

if [ -z "$CRDB_NAME" ]; then
  echo "CRDB service name is the Redis database service in the redis-enterprise namespace."
  echo "Example: my-crdb-production"
  CRDB_NAME="$(prompt_with_default "CRDB service name")"
fi

[ -n "$KUBE_CONTEXT" ] || fail "Kubernetes context is required"
[ -n "$CRDB_NAME" ] || fail "CRDB service name is required"

if [ -z "$REDIS_PORT" ]; then
  echo "Redis port is optional. Leave it blank to auto-discover it from the Service."
  REDIS_PORT="$(prompt_with_default "Redis port" "")"
fi

JOB_NAME="$(kubectl create --dry-run=client -f "$MANIFEST" -o jsonpath='{.metadata.name}')"
[ -n "$JOB_NAME" ] || fail "Could not determine Job name from $MANIFEST"

ENV_ARGS=()
if [ -n "$CRDB_NAME" ]; then
  ENV_ARGS+=("CRDB_NAME=$CRDB_NAME")
fi
if [ -n "$REDIS_PORT" ]; then
  ENV_ARGS+=("REDIS_PORT=$REDIS_PORT")
fi

TMP_RENDERED="$(mktemp)"
trap 'rm -f "$TMP_RENDERED"' EXIT

if [ "${#ENV_ARGS[@]}" -gt 0 ]; then
  kubectl set env --local -f "$MANIFEST" "${ENV_ARGS[@]}" -o yaml > "$TMP_RENDERED"
else
  cp "$MANIFEST" "$TMP_RENDERED"
fi

if [ "$DELETE_EXISTING" = true ]; then
  kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --context "$KUBE_CONTEXT" --ignore-not-found >/dev/null
fi

kubectl apply -f "$TMP_RENDERED" -n "$NAMESPACE" --context "$KUBE_CONTEXT"

echo ""
echo "Applied Job: $JOB_NAME"
echo "Manifest: $MANIFEST"
echo "Context: $KUBE_CONTEXT"
if [ -n "$CRDB_NAME" ]; then
  echo "CRDB_NAME: $CRDB_NAME"
fi
if [ -n "$REDIS_PORT" ]; then
  echo "REDIS_PORT: $REDIS_PORT"
fi
