# Prometheus Monitoring Architecture for Dual-Region Redis Enterprise

## Overview

This document explains the monitoring architecture for a dual-region Active-Active Redis Enterprise deployment on AWS EKS.

## Architecture Principles

### 1. Regional Prometheus Instances

**Each region has its own Prometheus instance** that monitors only the local Redis Enterprise cluster.

**Why?**
- **Reduced Cross-Region Traffic**: Metrics are scraped locally (every 15 seconds), avoiding expensive cross-region data transfer
- **Lower Latency**: Local scraping is faster and more reliable
- **Regional Fault Isolation**: If one region fails, the other continues monitoring independently
- **Cost Optimization**: Cross-region data transfer costs can be significant at high scrape frequencies

### 2. Unified Grafana Dashboard

**One Grafana instance connects to both Prometheus instances** for a unified view.

**Why?**
- **Single Pane of Glass**: View metrics from both regions in one dashboard
- **Cross-Region Correlation**: Compare performance, identify replication issues, detect regional anomalies
- **Simplified Operations**: One UI for operators to monitor the entire system
- **Lower Query Frequency**: Grafana queries are user-initiated (not every 15 seconds), making cross-region queries acceptable

### 3. Internal LoadBalancers

**Prometheus is exposed via internal AWS LoadBalancers** (not internet-facing).

**Why?**
- **Security**: Metrics endpoints are not exposed to the internet
- **VPC Peering**: Uses existing VPC peering between regions (already required for Redis Active-Active)
- **No Additional Networking**: Leverages the same network path as Redis replication
- **Cost Effective**: Internal LBs are cheaper than internet-facing LBs

## Data Flow

### Metrics Collection (High Frequency - Every 15 Seconds)

```
Region 1:
  Redis Enterprise Cluster (HTTPS port 8070, path /v2)
    ↓ (local scrape)
  Prometheus Instance (Region 1)
    ↓ (stores locally)
  Local Storage (30 days retention)

Region 2:
  Redis Enterprise Cluster (HTTPS port 8070, path /v2)
    ↓ (local scrape)
  Prometheus Instance (Region 2)
    ↓ (stores locally)
  Local Storage (30 days retention)
```

**Key Point**: No cross-region traffic for metrics collection!

### Metrics Visualization (Low Frequency - User Queries)

```
User
  ↓ (port-forward or LoadBalancer)
Grafana (Region 1)
  ↓ (queries local)
Prometheus (Region 1) → Shows Region 1 metrics
  ↓ (queries via VPC peering + internal LB)
Prometheus (Region 2) → Shows Region 2 metrics
```

**Key Point**: Cross-region queries only when users view dashboards, not for data collection!

## Deployment Options

### Option A: Unified Grafana (Recommended for Most Use Cases)

**Setup:**
1. Deploy monitoring stack to both regions
2. Configure one Grafana to connect to both Prometheus instances
3. Use that Grafana as your primary monitoring dashboard

**Pros:**
- Single dashboard for entire system
- Easy cross-region comparison
- Simplified operations

**Cons:**
- Grafana queries cross-region (acceptable for user-initiated queries)
- Single point of failure for visualization (Prometheus data still safe)

**Best For:**
- Teams that want unified monitoring
- Troubleshooting cross-region issues
- Comparing regional performance

### Option B: Separate Grafana Instances

**Setup:**
1. Deploy monitoring stack to both regions
2. Use each Grafana independently
3. Each shows only local metrics

**Pros:**
- Complete regional isolation
- No cross-region queries at all
- Simpler network configuration

**Cons:**
- Need to check two dashboards
- Harder to correlate cross-region issues
- More operational overhead

**Best For:**
- Maximum regional isolation requirements
- Compliance requirements for data locality
- Teams managing regions independently

## Network Requirements

### Within Each Region

1. **Cross-Namespace Communication** (monitoring ↔ redis-enterprise)
   - Enabled by default in Kubernetes
   - Prometheus scrapes Redis Enterprise v2 metrics on `https://<prom-metrics-service>:8070/v2`

2. **RBAC Permissions**
   - ClusterRole allows Prometheus to discover services across namespaces
   - Automatically configured by deployment scripts

### Cross-Region (For Unified Grafana)

1. **VPC Peering**
   - Already required for Redis Active-Active replication
   - No additional setup needed

2. **Internal LoadBalancer**
   - Exposes Prometheus within VPC (not internet)
   - Accessible via VPC peering

3. **Security Groups**
   - Allow port 9090 from remote VPC CIDR
   - Automatically configured for internal LBs

## Cost Considerations

### Metrics Collection (Local)
- **Data Transfer**: FREE (within same AZ/region)
- **Frequency**: Every 15 seconds
- **Volume**: ~100-500 KB/scrape depending on cluster size

### Grafana Queries (Cross-Region)
- **Data Transfer**: $0.01-0.02 per GB (cross-region)
- **Frequency**: Only when users view dashboards
- **Volume**: Typically <10 MB per dashboard load
- **Monthly Cost**: Usually <$10/month for typical usage

**Conclusion**: The cost of cross-region Grafana queries is negligible compared to the value of unified monitoring.

## Scalability

### Prometheus Storage

- **Default**: 10Gi per region
- **Retention**: 30 days
- **Scaling**: Increase PVC size if needed

### Grafana Performance

- Queries both Prometheus instances in parallel
- Each Prometheus handles its own region's data
- No performance bottleneck for typical deployments

### High Availability (Optional)

For production, consider:
- **Prometheus**: Deploy with replicas (requires Thanos or similar)
- **Grafana**: Deploy with replicas + shared database
- **LoadBalancer**: Use multi-AZ for higher availability

## Security Best Practices

1. **Set a Secure Grafana Password**: Use a strong `grafana_admin_password` value before enabling in-cluster Grafana.
2. **Use Internal LoadBalancers**: Never expose Prometheus to internet
3. **Enable TLS**: Configure TLS for Prometheus and Grafana in production
4. **Restrict Security Groups**: Limit access to known IP ranges
5. **Enable Authentication**: Use OAuth/LDAP for Grafana in production
6. **Audit Logs**: Enable audit logging for compliance

## Troubleshooting

### Grafana Can't Connect to Remote Prometheus

**Check:**
1. LoadBalancer is provisioned: `kubectl get svc prometheus-external -n monitoring` (only for the `--with-grafana` workflow)
2. VPC peering is active
3. Security groups allow port 9090
4. DNS resolution works from Grafana pod

### High Cross-Region Costs

**Solutions:**
1. Reduce dashboard refresh frequency
2. Use separate Grafana instances (Option B)
3. Implement Prometheus federation (advanced)

### Metrics Not Appearing

**Check:**
1. ServiceMonitor exists: `kubectl get servicemonitor -n redis-enterprise`
2. Prometheus targets are UP: Check Prometheus UI → Targets
3. Redis Enterprise metrics service exists: `kubectl get svc -l redis.io/service=prom-metrics`
