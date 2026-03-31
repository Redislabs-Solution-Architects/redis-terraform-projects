# Terraform-Generated Monitoring Stack Workflow

## 📋 Overview

The Prometheus monitoring stack is now **fully managed by Terraform**. All Kubernetes YAML manifests are auto-generated from templates, making configuration changes simple and consistent across both regions.

## 🎯 Key Benefits

✅ **Single Source of Truth**: All configuration in `terraform.tfvars`  
✅ **No Hardcoded Values**: Everything is parameterized  
✅ **Consistent Across Regions**: Same configuration applied to both regions  
✅ **Easy Updates**: Change one variable, regenerate all files  
✅ **Version Controlled**: Templates are in Git, generated files are not  
✅ **Infrastructure as Code**: Monitoring configuration follows IaC best practices  

## 🏗️ Architecture

```
terraform.tfvars (Your Configuration)
        ↓
    terraform apply
        ↓
    ┌─────────────────────────────────────────┐
    │  Terraform reads templates/*.yaml.tpl   │
    │  Injects variables from terraform.tfvars│
    │  Generates YAML files                   │
    └─────────────────────────────────────────┘
        ↓
    generated/
    ├── region1/
    │   ├── 00-namespace.yaml
    │   ├── 02-prometheus-instance.yaml
    │   ├── servicemonitor.yaml
    │   ├── prometheus-rules.yaml
    │   ├── 03-grafana.yaml (if grafana_enabled=true)
    │   └── 04-prometheus-loadbalancer.yaml (if grafana_enabled=true)
    └── region2/
        ├── 00-namespace.yaml
        ├── 02-prometheus-instance.yaml
        ├── servicemonitor.yaml
        ├── prometheus-rules.yaml
        ├── 03-grafana.yaml (if grafana_enabled=true)
        └── 04-prometheus-loadbalancer.yaml (if grafana_enabled=true)
        ↓
    ./deploy-monitoring.sh
        ↓
    Kubernetes Clusters (Region 1 & Region 2)
```

## 🚀 Complete Workflow

### 1. Configure Monitoring Settings

Edit `terraform.tfvars` to customize your monitoring stack:

```hcl
# Prometheus Configuration
prometheus_enabled              = true
prometheus_replicas             = 2
prometheus_retention            = "30d"
prometheus_storage_size         = "50Gi"
prometheus_memory_request       = "2Gi"
prometheus_memory_limit         = "8Gi"
prometheus_cpu_request          = "500m"
prometheus_cpu_limit            = "2000m"
prometheus_scrape_interval      = "15s"

# Grafana Configuration
grafana_enabled                 = false  # Use local Grafana (recommended)
grafana_admin_password          = "your-secure-password"
grafana_replicas                = 1
grafana_memory_request          = "256Mi"
grafana_memory_limit            = "512Mi"

# Alert Thresholds
alert_redis_memory_threshold     = 90
alert_redis_cpu_threshold        = 80
alert_redis_connection_threshold = 10000

# Redis Metrics Configuration
redis_metrics_port              = 8070
redis_metrics_scheme            = "https"
redis_metrics_path              = "/v2"
```

### 2. Generate Configuration Files

```bash
cd redis-enterprise-software/eks-dual-region-active-active

# Generate all monitoring YAML files
terraform apply
```

**What happens:**
- Terraform reads templates from `templates/*.yaml.tpl`
- Injects your variables from `terraform.tfvars`
- Generates region-specific YAML files in `generated/region1/` and `generated/region2/`
- Creates `config.env` with cluster information

### 3. Deploy Monitoring Stack

```bash
cd post-deployment/02-prometheus-monitoring

# Deploy to both regions (recommended)
./deploy-monitoring.sh both

# Or deploy to specific region
./deploy-monitoring.sh region1
./deploy-monitoring.sh region2
```

**What happens:**
- Script reads `config.env` for cluster information
- Applies YAML files from `generated/region1/` or `generated/region2/`
- Deploys Prometheus Operator, Prometheus, ServiceMonitors, and Alert Rules
- Optionally deploys Grafana (if `grafana_enabled=true`)

### 4. Verify Deployment

```bash
# Check Prometheus pods
kubectl get pods -n monitoring --context region1
kubectl get pods -n monitoring --context region2

# Check ServiceMonitors
kubectl get servicemonitor -n redis-enterprise --context region1
kubectl get servicemonitor -n redis-enterprise --context region2

# Port-forward to Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
# Open http://localhost:9090
```

## 🔧 Making Configuration Changes

### Example: Increase Prometheus Memory

1. **Edit `terraform.tfvars`:**
   ```hcl
   prometheus_memory_limit = "16Gi"  # Changed from 8Gi
   ```

2. **Regenerate files:**
   ```bash
   terraform apply
   ```

3. **Redeploy:**
   ```bash
   cd post-deployment/02-prometheus-monitoring
   ./deploy-monitoring.sh both
   ```

### Example: Change Alert Thresholds

1. **Edit `terraform.tfvars`:**
   ```hcl
   alert_redis_memory_threshold = 85  # Changed from 90
   alert_redis_cpu_threshold    = 75  # Changed from 80
   ```

2. **Regenerate and redeploy:**
   ```bash
   terraform apply
   cd post-deployment/02-prometheus-monitoring
   ./deploy-monitoring.sh both
   ```

## 📁 File Structure

```
post-deployment/02-prometheus-monitoring/
├── templates/                          # Template files (version controlled)
│   ├── 00-namespace.yaml.tpl
│   ├── 02-prometheus-instance.yaml.tpl
│   ├── 03-grafana.yaml.tpl
│   ├── 04-prometheus-loadbalancer.yaml.tpl
│   ├── servicemonitor.yaml.tpl
│   └── prometheus-rules.yaml.tpl
├── generated/                          # Generated files (NOT in Git)
│   ├── region1/
│   │   ├── 00-namespace.yaml
│   │   ├── 02-prometheus-instance.yaml
│   │   ├── 03-grafana.yaml
│   │   ├── 04-prometheus-loadbalancer.yaml
│   │   ├── servicemonitor.yaml
│   │   └── prometheus-rules.yaml
│   └── region2/
│       └── (same files as region1)
├── deploy-monitoring.sh                # Deployment script
├── README.md                           # Main documentation
└── TERRAFORM-WORKFLOW.md               # This file
```

## ⚙️ Available Variables

See `variables.tf` (lines 492-658) for all available monitoring variables:

- **Prometheus**: replicas, retention, storage, CPU/memory limits, scrape intervals
- **Grafana**: enabled flag, replicas, admin password, CPU/memory limits
- **ServiceMonitor**: metrics port, scheme, path
- **Alert Rules**: memory/CPU/connection thresholds

## 🎓 Best Practices

1. **Always use Terraform to generate files** - Don't manually edit generated YAML files
2. **Keep templates in version control** - Templates are the source of truth
3. **Exclude generated/ from Git** - Already in `.gitignore`
4. **Test changes in one region first** - Use `./deploy-monitoring.sh region1`
5. **Document custom changes** - Add comments to `terraform.tfvars`

## 🔍 Troubleshooting

### Generated files not found

**Error:** `Generated files not found at generated/region1/`

**Solution:**
```bash
cd redis-enterprise-software/eks-dual-region-active-active
terraform apply
```

### Variables not taking effect

**Problem:** Changed `terraform.tfvars` but YAML files unchanged

**Solution:** Run `terraform apply` to regenerate files

### Different configuration per region

**Current limitation:** Both regions use the same configuration variables.

**Workaround:** If you need different settings per region, you can:
1. Generate files with Terraform
2. Manually edit the generated files for one region
3. Deploy with the script

**Note:** Manual edits will be lost on next `terraform apply`

## 📚 Related Documentation

- [README.md](./README.md) - Main monitoring stack documentation
- [LOCAL-GRAFANA-SETUP.md](./LOCAL-GRAFANA-SETUP.md) - Local Grafana setup guide
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Detailed architecture explanation
- [NETWORK-SECURITY.md](./NETWORK-SECURITY.md) - Security configuration guide
