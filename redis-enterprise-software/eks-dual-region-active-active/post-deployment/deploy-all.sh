#!/bin/bash

#==============================================================================
# MASTER DEPLOYMENT SCRIPT
#==============================================================================
# This script deploys post-infrastructure components in the correct order.
# Active-Active CRDB creation is intentionally gated behind a manual license
# upload in both Redis Enterprise admin UIs.
#==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

prompt_monitoring_mode() {
    echo ""
    echo "Monitoring deployment mode:"
    echo "  1. Local Grafana only (recommended, no in-cluster Grafana)"
    echo "  2. In-cluster Grafana and Prometheus LoadBalancers"
    echo ""
    read -r -p "Select monitoring mode [1-2]: " MONITORING_OPTION

    case "${MONITORING_OPTION}" in
        1)
            MONITORING_ARGS=()
            ;;
        2)
            MONITORING_ARGS=(--with-grafana)
            ;;
        *)
            fail "Invalid monitoring mode selection"
            ;;
    esac
}

confirm_license_checkpoint() {
    echo ""
    echo "Manual checkpoint required:"
    echo "  1. Log in to the Region 1 and Region 2 Redis Enterprise admin UIs"
    echo "  2. Upload the license in both clusters"
    echo "  3. Confirm both RECs remain Running after licensing"
    echo ""
    read -r -p "Type 'licensed' to continue: " LICENSE_CONFIRMATION
    if [ "$LICENSE_CONFIRMATION" != "licensed" ]; then
        echo -e "${RED}❌ License checkpoint not confirmed. Stopping before CRDB creation.${NC}"
        exit 1
    fi
}

echo ""
echo "=========================================================================="
echo "  Redis Enterprise Active-Active Deployment"
echo "=========================================================================="
echo ""

# Check if config.env exists
require_command aws
require_command kubectl

if [ ! -f "$SCRIPT_DIR/config.env" ]; then
    fail "config.env not found. Run terraform apply first."
fi

# Load configuration
echo -e "${BLUE}📋 Loading configuration from config.env...${NC}"
source "$SCRIPT_DIR/config.env"

# Validate required variables
echo -e "${BLUE}🔍 Validating configuration...${NC}"
REQUIRED_VARS=(
    "PROJECT_PREFIX"
    "AWS_REGION1"
    "AWS_REGION2"
    "REGION1_CLUSTER_NAME"
    "REGION2_CLUSTER_NAME"
    "REGION1_REC_NAME"
    "REGION2_REC_NAME"
    "NAMESPACE"
    "REGION1_CONTEXT"
    "REGION2_CONTEXT"
)

ALL_VALID=true
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}❌ $var is not set${NC}"
        ALL_VALID=false
    fi
done

if [ "$ALL_VALID" = false ]; then
    echo -e "${RED}❌ Configuration validation failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Configuration validated${NC}"
echo ""
echo "Deployment Configuration:"
echo "  Project: $PROJECT_PREFIX"
echo "  Region 1: $AWS_REGION1 (Cluster: $REGION1_CLUSTER_NAME)"
echo "  Region 2: $AWS_REGION2 (Cluster: $REGION2_CLUSTER_NAME)"
echo "  Namespace: $NAMESPACE"
echo ""

[ -n "${AWS_PROFILE:-}" ] || fail "AWS_PROFILE is not set in config.env"

# Configure kubectl contexts
echo -e "${BLUE}🔧 Configuring kubectl contexts...${NC}"
aws eks update-kubeconfig --region "$AWS_REGION1" --name "$REGION1_CLUSTER_NAME" --alias "$REGION1_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
aws eks update-kubeconfig --region "$AWS_REGION2" --name "$REGION2_CLUSTER_NAME" --alias "$REGION2_CONTEXT" --profile "$AWS_PROFILE" >/dev/null
echo -e "${GREEN}✅ Kubectl contexts configured${NC}"
echo ""

# Verify clusters are accessible
echo -e "${BLUE}🔍 Verifying cluster access...${NC}"
kubectl get nodes --context "$REGION1_CONTEXT" > /dev/null 2>&1 || fail "Cannot access cluster in $AWS_REGION1"
kubectl get nodes --context "$REGION2_CONTEXT" > /dev/null 2>&1 || fail "Cannot access cluster in $AWS_REGION2"
echo -e "${GREEN}✅ Both clusters accessible${NC}"
echo ""

# Verify REC status
echo -e "${BLUE}🔍 Verifying Redis Enterprise Clusters...${NC}"
REC1_STATUS=$(kubectl get rec "$REGION1_REC_NAME" -n "$NAMESPACE" --context "$REGION1_CONTEXT" -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
REC2_STATUS=$(kubectl get rec "$REGION2_REC_NAME" -n "$NAMESPACE" --context "$REGION2_CONTEXT" -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")

if [ "$REC1_STATUS" != "Running" ]; then
    echo -e "${RED}❌ REC in $AWS_REGION1 is not Running (Status: $REC1_STATUS)${NC}"
    exit 1
fi

if [ "$REC2_STATUS" != "Running" ]; then
    echo -e "${RED}❌ REC in $AWS_REGION2 is not Running (Status: $REC2_STATUS)${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Both RECs are Running${NC}"
echo ""

# Deployment menu
echo "=========================================================================="
echo "  Deployment Options"
echo "=========================================================================="
echo ""
echo "1. Deploy Active-Active CRDB only (post-license)"
echo "2. Deploy Prometheus Monitoring only"
echo "3. Deploy Automated Backups only"
echo "4. Deploy Redis Monitoring UI only"
echo "5. Deploy CRDB, monitoring, backups, and UI (post-license)"
echo "6. Exit"
echo ""
read -p "Select option [1-6]: " OPTION

case $OPTION in
    1)
        confirm_license_checkpoint
        echo -e "${BLUE}📦 Deploying Active-Active CRDB...${NC}"
        cd "$SCRIPT_DIR/01-active-active-crdb"
        ./deploy-crdb.sh
        ;;
    2)
        prompt_monitoring_mode
        echo -e "${BLUE}📦 Deploying Prometheus Monitoring...${NC}"
        cd "$SCRIPT_DIR/02-prometheus-monitoring"
        ./deploy-monitoring.sh "${MONITORING_ARGS[@]}"
        ;;
    3)
        echo -e "${BLUE}📦 Deploying Automated Backups...${NC}"
        cd "$SCRIPT_DIR/03-automated-backups"
        ./deploy-backups.sh
        ;;
    4)
        echo -e "${BLUE}📦 Deploying Redis Monitoring UI...${NC}"
        cd "$SCRIPT_DIR/04-redis-monitoring-ui"
        ./deploy.sh
        ;;
    5)
        confirm_license_checkpoint
        prompt_monitoring_mode
        echo -e "${BLUE}📦 Deploying ALL components...${NC}"
        echo ""
        
        # Deploy in order
        echo -e "${YELLOW}[1/4] Deploying Active-Active CRDB...${NC}"
        cd "$SCRIPT_DIR/01-active-active-crdb" && ./deploy-crdb.sh
        echo ""
        
        echo -e "${YELLOW}[2/4] Deploying Prometheus Monitoring...${NC}"
        cd "$SCRIPT_DIR/02-prometheus-monitoring" && ./deploy-monitoring.sh "${MONITORING_ARGS[@]}"
        echo ""
        
        echo -e "${YELLOW}[3/4] Deploying Automated Backups...${NC}"
        cd "$SCRIPT_DIR/03-automated-backups" && ./deploy-backups.sh
        echo ""
        
        echo -e "${YELLOW}[4/4] Deploying Redis Monitoring UI...${NC}"
        cd "$SCRIPT_DIR/04-redis-monitoring-ui" && ./deploy.sh
        echo ""
        ;;
    6)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option${NC}"
        exit 1
        ;;
esac

echo ""
echo "=========================================================================="
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo "=========================================================================="
echo ""
