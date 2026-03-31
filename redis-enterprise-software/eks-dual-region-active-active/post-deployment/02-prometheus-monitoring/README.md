# Prometheus Monitoring Stack for Redis Enterprise

Complete Prometheus monitoring solution for Redis Enterprise on EKS with dual-region Active-Active deployment.

## 📋 Overview

This monitoring stack provides:

- **Prometheus Operator**: Manages Prometheus instances and monitoring configuration
- **Prometheus**: Collects and stores metrics from Redis Enterprise clusters
- **Local Grafana** (recommended ⭐): Visualizes metrics running on your Mac
- **ServiceMonitors**: Automatic discovery and scraping of Redis Enterprise metrics
- **Alert Rules**: Pre-configured alerts for Redis Enterprise health

## 💡 Recommended: Use Local Grafana

**By default, this deployment uses Grafana running locally on your Mac** for better performance, simpler setup, and persistent configuration.

**Benefits:**
- ✅ Simpler setup (no Kubernetes deployment)
- ✅ Better performance (UI runs locally)
- ✅ Persistent dashboards (survive cluster rebuilds)
- ✅ Easy updates (`brew upgrade grafana`)
- ✅ No cluster resources used

**See [LOCAL-GRAFANA-SETUP.md](./LOCAL-GRAFANA-SETUP.md) for complete setup instructions.**

If you need in-cluster Grafana (for team access), use the `--with-grafana` flag and set `grafana_enabled = true` in Terraform first.

## 🏗️ Architecture

### Regional Deployment Model

**Each region has its own independent monitoring stack:**

```
┌─────────────────────────────────────────────────────────────┐
│                    REGION 1 (us-east-1)                      │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │           Monitoring Namespace                          ││
│  │                                                         ││
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ ││
│  │  │Prometheus│◄─│ Grafana  │  │ Prometheus Operator  │ ││
│  │  └────┬─────┘  └──────────┘  └──────────────────────┘ ││
│  └───────┼──────────────────────────────────────────────────┘│
│          │ Scrapes port 8070                                 │
│  ┌───────▼──────────────────────────────────────────────────┐│
│  │      Redis Enterprise Namespace                         ││
│  │                                                         ││
│  │  ┌──────────────────────────────────────────────────┐  ││
│  │  │  Redis Enterprise Cluster (Region 1)             │  ││
│  │  │  - Metrics Service (port 8070)                   │  ││
│  │  │  - ServiceMonitor (discovery config)             │  ││
│  │  └──────────────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    REGION 2 (us-east-2)                      │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │           Monitoring Namespace                          ││
│  │                                                         ││
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ ││
│  │  │Prometheus│◄─│ Grafana  │  │ Prometheus Operator  │ ││
│  │  └────┬─────┘  └──────────┘  └──────────────────────┘ ││
│  └───────┼──────────────────────────────────────────────────┘│
│          │ Scrapes port 8070                                 │
│  ┌───────▼──────────────────────────────────────────────────┐│
│  │      Redis Enterprise Namespace                         ││
│  │                                                         ││
│  │  ┌──────────────────────────────────────────────────┐  ││
│  │  │  Redis Enterprise Cluster (Region 2)             │  ││
│  │  │  - Metrics Service (port 8070)                   │  ││
│  │  │  - ServiceMonitor (discovery config)             │  ││
│  │  └──────────────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### Key Architectural Decisions

1. **Regional Isolation**: Each region has its own Prometheus instance
   - Reduces cross-region network traffic for metrics scraping
   - Provides regional fault isolation
   - Each Prometheus only monitors its local Redis Enterprise cluster

2. **Cross-Namespace Monitoring**: Within each region
   - Prometheus in `monitoring` namespace
   - Redis Enterprise in `redis-enterprise` namespace
   - ServiceMonitor enables automatic discovery

3. **No Cross-Region Scraping**: Prometheus does NOT scrape across regions
   - Avoids cross-region latency and costs for high-frequency scraping
   - Each region is self-contained for data collection

4. **Unified Grafana View**: One Grafana connects to both Prometheus instances
   - Choose one region to host your primary Grafana instance
   - Grafana queries both Prometheus instances via LoadBalancer
   - Provides unified dashboards showing metrics from both regions
   - Enables cross-region comparison and correlation

## 📦 Components

### 1. Namespace (`00-namespace.yaml`)
Creates the `monitoring` namespace for all monitoring components.

### 2. Prometheus Operator (`01-prometheus-operator.yaml`)
- Deploys the Prometheus Operator from the official bundle
- Creates necessary CRDs (Prometheus, ServiceMonitor, PrometheusRule, etc.)
- Sets up RBAC permissions

### 3. Prometheus Instance (`02-prometheus-instance.yaml`)
- Deploys a Prometheus instance in the `monitoring` namespace
- Configured for cross-namespace service discovery
- Includes ClusterRole for accessing services across namespaces
- Retention: 30 days
- Storage: 10Gi

### 4. Grafana (`03-grafana.yaml`)
- Visualization platform for Prometheus metrics
- Pre-configured with local Prometheus datasource
- Supports dual datasources (local + remote region)
- Admin password comes from the Terraform-managed `grafana-admin` secret
- Only generated when `grafana_enabled = true`

### 5. Prometheus LoadBalancer (`04-prometheus-loadbalancer.yaml`)
- Exposes Prometheus via internal AWS LoadBalancer
- Enables cross-region Grafana access
- Uses internal LB (not internet-facing) for security
- Only generated and deployed for the in-cluster Grafana path

### 6. Dual Datasource Configuration (`05-configure-dual-datasources.sh`)
- Script to configure Grafana with both Prometheus instances
- Automatically discovers remote Prometheus LoadBalancer URL
- Updates Grafana datasources and restarts the pod
- Run after deploying to both regions

### 7. ServiceMonitor (`servicemonitor.yaml`)
- Deployed in `redis-enterprise` namespace
- Automatically discovers Redis Enterprise metrics services
- Scrapes Redis Enterprise v2 metrics from `https://<prom-metrics-service>:8070/v2`
- Scrape interval: 15 seconds

### 8. Prometheus Rules (`prometheus-rules.yaml`)
- Alert rules for Redis Enterprise health monitoring
- Deployed in `monitoring` namespace

## 🚀 Deployment

### Prerequisites

1. **EKS clusters deployed** in one or both regions
2. **Redis Enterprise clusters** running (or will be deployed)
3. **kubectl contexts** configured for the regions
4. **Terraform applied** to generate configuration files
5. **AWS CLI** configured with appropriate credentials
6. **Local Grafana** (recommended): `brew install grafana && brew services start grafana`

### Step 1: Generate Configuration Files with Terraform

All monitoring YAML files are **auto-generated by Terraform** from templates. This ensures consistency and makes configuration changes easy.

```bash
cd redis-enterprise-software/eks-dual-region-active-active

# Generate all configuration files (including monitoring YAML files)
terraform apply
```

**What gets generated:**
- `post-deployment/config.env` - Environment configuration
- `post-deployment/02-prometheus-monitoring/generated/region1/*.yaml` - Region 1 monitoring manifests
- `post-deployment/02-prometheus-monitoring/generated/region2/*.yaml` - Region 2 monitoring manifests

**To customize monitoring settings**, edit `terraform.tfvars`:

```hcl
# Prometheus configuration
prometheus_replicas       = 2
prometheus_storage_size   = "50Gi"
prometheus_retention      = "30d"
prometheus_memory_limit   = "8Gi"

# Grafana configuration (if deploying to cluster)
grafana_enabled          = false  # true to deploy Grafana to cluster
grafana_admin_password   = "your-secure-password"

# Alert thresholds
alert_redis_memory_threshold     = 90
alert_redis_cpu_threshold        = 80
alert_redis_connection_threshold = 10000
```

Then run `terraform apply` again to regenerate the files with your new settings.

### Step 2: Deploy the Stack

The deployment script supports flexible region targeting and Grafana options:

```bash
cd redis-enterprise-software/eks-dual-region-active-active/post-deployment/02-prometheus-monitoring

# Deploy to both regions (default: uses local Grafana - recommended ⭐)
./deploy-monitoring.sh
# or
./deploy-monitoring.sh both

# Deploy to region 1 only
./deploy-monitoring.sh region1

# Deploy to region 2 only
./deploy-monitoring.sh region2

# Deploy with in-cluster Grafana (for team access)
# First, set grafana_enabled=true in terraform.tfvars and run terraform apply
./deploy-monitoring.sh both --with-grafana
```

### What the Script Does

For each selected region, the script will:

1. **Load configuration** from `config.env` (generated by Terraform)
2. **Validate** required variables from `config.env`
3. **Configure** kubeconfig contexts using `aws eks update-kubeconfig` and the configured `AWS_PROFILE`
4. **Use generated YAML files** from `generated/region1/` or `generated/region2/`
5. **Create** the `monitoring` namespace
6. **Install** the pinned Prometheus Operator bundle version from Terraform config
7. **Deploy** Prometheus instance with cross-namespace discovery
8. **Deploy** Grafana and Prometheus LoadBalancers only when `--with-grafana` is used and `grafana_enabled=true`
9. **Deploy** ServiceMonitor for automatic Redis Enterprise discovery
10. **Deploy** Prometheus alert rules for Redis health monitoring

### Configuration Auto-Discovery

The script automatically:
- Reads cluster names, regions, contexts, and operator version from `config.env`
- Refreshes kubeconfig contexts using `AWS_PROFILE`
- Configures cross-namespace monitoring between `monitoring` and `redis-enterprise` namespaces
- Uses region-specific generated YAML files from Terraform

## 🔗 Unified Grafana Setup (Dual-Region Monitoring)

After deploying to both regions with in-cluster Grafana enabled, you can configure one Grafana instance to query both Prometheus instances for a unified view.

### Step 1: Deploy to Both Regions

```bash
./deploy-monitoring.sh both --with-grafana
```

### Step 2: Wait for LoadBalancers

Wait for the Prometheus LoadBalancers to be provisioned (2-3 minutes):

```bash
# Check Region 1
kubectl get svc prometheus-external -n monitoring --context region1 -w

# Check Region 2
kubectl get svc prometheus-external -n monitoring --context region2 -w
```

### Step 3: Configure Dual Datasources

Choose which region's Grafana you want to use as your primary dashboard:

```bash
# Option A: Use Region 1 Grafana to see both regions
./05-configure-dual-datasources.sh region1

# Option B: Use Region 2 Grafana to see both regions
./05-configure-dual-datasources.sh region2
```

This script will:
1. Discover the remote Prometheus LoadBalancer URL
2. Update Grafana's datasource configuration
3. Restart Grafana to apply changes

### Step 4: Verify Dual Datasources

1. Access Grafana (using the region you configured):
   ```bash
   kubectl port-forward -n monitoring svc/grafana 3000:3000 --context region1
   ```

2. Login as `admin` using the password from the `grafana-admin` secret:
   ```bash
   kubectl get secret grafana-admin -n monitoring --context region1 -o jsonpath='{.data.password}' | base64 -d
   ```

3. Go to **Configuration → Data Sources**

4. You should see:
   - **Prometheus-us-east-1** (or your local region)
   - **Prometheus-us-east-2** (or your remote region)

5. Test both datasources by going to **Explore** and running:
   ```promql
   redis_up
   ```

### Benefits of Unified Grafana

- **Single Dashboard**: View metrics from both regions side-by-side
- **Cross-Region Comparison**: Compare performance across regions
- **Correlation**: Identify cross-region issues (e.g., replication lag)
- **Simplified Operations**: One UI for all monitoring

### Alternative: Keep Separate Grafana Instances

If you prefer regional isolation, you can keep separate Grafana instances:
- Each region has its own Grafana
- Each Grafana only shows local metrics
- Simpler network configuration
- Better fault isolation

## 🔍 Verification

### Check Deployment Status

```bash
# Check Prometheus Operator
kubectl get deployment prometheus-operator -n default --context region1

# Check Prometheus instance
kubectl get prometheus -n monitoring --context region1
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --context region1

# Check Grafana (only if deployed with --with-grafana)
kubectl get pods -n monitoring -l app=grafana --context region1

# Check ServiceMonitor
kubectl get servicemonitor -n redis-enterprise --context region1

# Check Prometheus Rules
kubectl get prometheusrule -n monitoring --context region1
```

### Access UIs

#### Prometheus

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
```
Open: http://localhost:9090

#### Grafana

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000 --context region1
```
Open: http://localhost:3000
- Username: `admin`
- Password: `kubectl get secret grafana-admin -n monitoring --context region1 -o jsonpath='{.data.password}' | base64 -d`

### Verify Metrics Collection

1. Port-forward Prometheus UI (see above)
2. Go to **Status → Targets**
3. Look for `redis-enterprise/redis-enterprise-metrics` targets
4. Verify they are in **UP** state

### Query Metrics

In Prometheus UI, try these queries:

```promql
# Check if Redis is up
redis_up

# Total requests per database
rate(bdb_total_req[5m])

# Memory usage by database
bdb_used_memory

# Number of connections
bdb_conns

# Available memory on nodes
node_available_memory
```

## 🔐 Network Security

### Cross-Namespace Communication

The monitoring stack requires cross-namespace communication:
- **Source**: Prometheus pods in `monitoring` namespace
- **Destination**: Redis Enterprise services in `redis-enterprise` namespace
- **Port**: 8070 (HTTPS)

See [NETWORK-SECURITY.md](./NETWORK-SECURITY.md) for detailed security configuration.

### AWS Security Groups

Port 8070 must be open between EKS nodes. This is typically configured automatically by the Terraform modules in this project.

To verify:
```bash
# Get node security group
NODE_SG_ID=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Check for port 8070 rule
aws ec2 describe-security-groups --group-ids $NODE_SG_ID --region <region> \
  --query 'SecurityGroups[0].IpPermissions[?ToPort==`8070`]'
```

## 📊 Grafana Dashboards

### Import Redis Enterprise Dashboards

1. Access Grafana UI (see above)
2. Go to **Dashboards → Import**
3. Import the following dashboard IDs from Grafana.com:
   - **Redis Enterprise Cluster**: 14615
   - **Redis Enterprise Database**: 14614
   - **Redis Enterprise Node**: 14616

Or use the JSON files from Redis Labs:
- https://github.com/RedisLabs/redis-enterprise-k8s-docs/tree/master/grafana

## 🚨 Alerts

Pre-configured alerts include:
- Redis Enterprise cluster down
- High memory usage
- High CPU usage
- Database connection issues
- Replication lag

View alerts in Prometheus UI: **Alerts** tab

## 🛠️ Troubleshooting

### ServiceMonitor Not Discovered

**Problem**: ServiceMonitor doesn't appear in Prometheus targets

**Solutions**:
1. Verify RBAC: `kubectl get clusterrole prometheus-k8s`
2. Check Prometheus logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus`
3. Verify ServiceMonitor: `kubectl get servicemonitor -n redis-enterprise`

### Targets Show as "Down"

**Problem**: Targets appear but status is "Down"

**Solutions**:
1. Check network connectivity (see NETWORK-SECURITY.md)
2. Verify port 8070 is open in security groups
3. Check Redis Enterprise service: `kubectl get svc -n redis-enterprise -l redis.io/service=prom-metrics`
4. Verify Redis Enterprise pods: `kubectl get pods -n redis-enterprise`

### No Metrics in Grafana

**Problem**: Grafana shows "No data"

**Solutions**:
1. Verify Prometheus datasource: **Configuration → Data Sources**
2. Test connection to Prometheus
3. Check if Prometheus is collecting metrics (see Prometheus UI → Targets)

## 📚 Additional Resources

- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Redis Enterprise Monitoring](https://redis.io/docs/latest/operate/kubernetes/re-clusters/connect-prometheus-operator/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Network Security Configuration](./NETWORK-SECURITY.md)

## 🔄 Cleanup

To remove the monitoring stack:

```bash
kubectl delete namespace monitoring --context region1
kubectl delete namespace monitoring --context region2
kubectl delete -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/bundle.yaml --context region1
kubectl delete -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/bundle.yaml --context region2
```
