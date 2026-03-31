# Quick Start Guide - Prometheus Monitoring

## TL;DR - Get Monitoring Running in 5 Minutes ⚡

This guide uses **local Grafana on your Mac** (recommended for best performance and simplicity).

### Step 1: Install Grafana on Mac (30 seconds)

```bash
brew install grafana
brew services start grafana
```

### Step 2: Deploy Prometheus to Both Regions (2-3 minutes)

```bash
cd redis-enterprise-software/eks-dual-region-active-active/post-deployment/02-prometheus-monitoring
./deploy-monitoring.sh both
```

This deploys Prometheus to both regions but **skips in-cluster Grafana and Prometheus LoadBalancers**. You'll use local Grafana plus port-forwarding instead.

### Step 3: Port-Forward Both Prometheus Instances

**Terminal 1 - Region 1:**
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
```

**Terminal 2 - Region 2:**
```bash
kubectl port-forward -n monitoring svc/prometheus 9091:9090 --context region2
```

### Step 4: Configure Grafana Datasources

1. Open **http://localhost:3000** (admin/admin - you'll be prompted to change password)
2. Go to **Configuration → Data Sources**
3. Click **Add data source** → Select **Prometheus**
4. Configure Region 1:
   - Name: `Prometheus-us-east-1`
   - URL: `http://localhost:9090`
   - Click **Save & Test** ✅
5. Click **Add data source** again → Select **Prometheus**
6. Configure Region 2:
   - Name: `Prometheus-us-east-2`
   - URL: `http://localhost:9091`
   - Click **Save & Test** ✅

### Step 5: Verify Metrics

1. Go to **Explore**
2. Select **Prometheus-us-east-1**
3. Run query: `redis_up`
4. Should return `1` (Redis is up) ✅
5. Switch to **Prometheus-us-east-2**
6. Run same query - should also return `1` ✅

**🎉 Done! You now have unified monitoring of both regions!**

## Common Commands

### Check Deployment Status

```bash
# Prometheus
kubectl get prometheus -n monitoring --context region1
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --context region1

# Grafana (only if you deployed with --with-grafana)
kubectl get pods -n monitoring -l app=grafana --context region1

# ServiceMonitor
kubectl get servicemonitor -n redis-enterprise --context region1
```

### Access Prometheus UI

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
```
Open: http://localhost:9090

### Access Grafana

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000 --context region1
```
Open: http://localhost:3000
Only applies if you deployed with `--with-grafana`. For the default path, use your local Grafana at `http://localhost:3000`.

### View Prometheus Targets

1. Access Prometheus UI (see above)
2. Go to **Status → Targets**
3. Look for `redis-enterprise/redis-enterprise-metrics`
4. Status should be **UP**

## Useful Queries

### Check Redis is Up
```promql
redis_up
```

### Total Requests per Second
```promql
rate(bdb_total_req[5m])
```

### Memory Usage
```promql
bdb_used_memory
```

### Number of Connections
```promql
bdb_conns
```

### Replication Lag (Active-Active)
```promql
bdb_crdt_syncer_ingress_bytes_decompressed
```

## Troubleshooting

### "config.env not found"
**Solution**: Run `terraform apply` first to generate the config file.

### "LoadBalancer pending"
**Solution**: Only relevant when using `--with-grafana`. Wait 2-3 minutes for AWS to provision the internal LoadBalancer.

### "Targets are DOWN"
**Solution**: 
1. Check Redis Enterprise is running: `kubectl get rec -n redis-enterprise`
2. Check metrics service exists: `kubectl get svc -n redis-enterprise -l redis.io/service=prom-metrics`
3. Check security groups allow port 8070

### "Can't connect to remote Prometheus"
**Solution**:
1. This only applies to the in-cluster Grafana dual-region path
1. Verify VPC peering is active
2. Check security groups allow port 9090
3. Verify LoadBalancer is provisioned

## What Gets Deployed?

### In Each Region:
- ✅ Prometheus Operator (manages Prometheus lifecycle)
- ✅ Prometheus Instance (collects metrics locally)
- ✅ ServiceMonitor (auto-discovers Redis Enterprise)
- ✅ PrometheusRules (alert definitions)

### Optional with `--with-grafana`:
- ✅ Grafana (in-cluster visualization)
- ✅ Internal Prometheus LoadBalancer (for cross-region in-cluster Grafana access)

### Network Configuration:
- ✅ Cross-namespace monitoring (monitoring → redis-enterprise)
- ✅ Internal LoadBalancer (not internet-facing)
- ✅ VPC peering support (for cross-region queries)
- ✅ Security groups configured

## Next Steps

1. **Change Grafana Password**: Edit `03-grafana.yaml` and redeploy
2. **Import Dashboards**: Import Redis Enterprise dashboards from Grafana.com
3. **Configure Alerts**: Set up Alertmanager for notifications
4. **Enable TLS**: Configure TLS for production deployments

## Architecture Summary

```
Region 1                          Region 2
┌─────────────────┐              ┌─────────────────┐
│ Prometheus      │              │ Prometheus      │
│ (local scrape)  │              │ (local scrape)  │
│       ↓         │              │       ↓         │
│ Redis Enterprise│              │ Redis Enterprise│
└─────────────────┘              └─────────────────┘
        ↑                                ↑
        └────────── Grafana ─────────────┘
              (queries both via LB)
```

**Key Points:**
- Each Prometheus scrapes **locally** (no cross-region scraping)
- Grafana queries **both** Prometheus instances
- Uses **VPC peering** (already exists for Redis replication)
- **Internal LoadBalancers** (secure, not internet-facing)

## Support

For detailed documentation, see:
- [README.md](./README.md) - Complete documentation
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Architecture deep-dive
- [NETWORK-SECURITY.md](./NETWORK-SECURITY.md) - Security configuration
