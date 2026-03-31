# Local Grafana Setup Guide

This guide shows how to use **Grafana running on your Mac** to monitor both Prometheus instances in your dual-region Redis Enterprise deployment.

## Why Local Grafana?

✅ **Simpler** - No Kubernetes deployment needed  
✅ **Faster** - UI runs locally, no network latency  
✅ **Persistent** - Dashboards survive cluster rebuilds  
✅ **Multi-Environment** - Monitor dev, staging, prod from one Grafana  
✅ **Easy Updates** - Just `brew upgrade grafana`  

## Prerequisites

- Homebrew installed on Mac
- kubectl configured with access to both regions
- Prometheus deployed to both regions (via `deploy-monitoring.sh`)

## Step 1: Install Grafana on Mac

```bash
# Install Grafana
brew install grafana

# Start Grafana service
brew services start grafana

# Or run in foreground (to see logs)
grafana-server --config=/opt/homebrew/etc/grafana/grafana.ini --homepath /opt/homebrew/opt/grafana/share/grafana
```

Grafana will be available at: **http://localhost:3000**

Default credentials:
- Username: `admin`
- Password: `admin` (you'll be prompted to change it)

## Step 2: Port-Forward Both Prometheus Instances

Open **two terminal windows**:

### Terminal 1: Region 1 Prometheus
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
```

### Terminal 2: Region 2 Prometheus
```bash
kubectl port-forward -n monitoring svc/prometheus 9091:9090 --context region2
```

**Note**: Region 1 on port 9090, Region 2 on port 9091 (different local ports!)

## Step 3: Add Prometheus Datasources to Grafana

### Option A: Via Grafana UI (Recommended for First Time)

1. Open **http://localhost:3000**
2. Login (admin/admin)
3. Go to **Configuration → Data Sources**
4. Click **Add data source**
5. Select **Prometheus**

**For Region 1:**
- Name: `Prometheus-us-east-1` (or your region name)
- URL: `http://localhost:9090`
- Click **Save & Test** - should show "Data source is working"

**For Region 2:**
- Click **Add data source** again
- Select **Prometheus**
- Name: `Prometheus-us-east-2` (or your region name)
- URL: `http://localhost:9091`
- Click **Save & Test** - should show "Data source is working"

### Option B: Via Configuration File (Advanced)

Create/edit: `~/.grafana/provisioning/datasources/prometheus.yaml`

```yaml
apiVersion: 1

datasources:
  # Region 1 Prometheus
  - name: Prometheus-us-east-1
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
    uid: prometheus-region1

  # Region 2 Prometheus
  - name: Prometheus-us-east-2
    type: prometheus
    access: proxy
    url: http://localhost:9091
    editable: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
    uid: prometheus-region2
```

Then restart Grafana:
```bash
brew services restart grafana
```

## Step 4: Verify Datasources

1. Go to **Explore** in Grafana
2. Select **Prometheus-us-east-1** from dropdown
3. Run query: `redis_up`
4. Should return `1` (Redis is up)
5. Switch to **Prometheus-us-east-2**
6. Run same query: `redis_up`
7. Should also return `1`

## Step 5: Import Redis Enterprise Dashboards

### From Grafana.com

1. Go to **Dashboards → Import**
2. Enter dashboard ID: **14615** (Redis Enterprise Cluster)
3. Click **Load**
4. Select datasource: **Prometheus-us-east-1**
5. Click **Import**

Repeat for other dashboards:
- **14614** - Redis Enterprise Database
- **14616** - Redis Enterprise Node

### Create Multi-Region Dashboard

Create a custom dashboard with panels showing both regions:

**Example Panel: Redis Memory Usage (Both Regions)**

1. Create new dashboard
2. Add panel
3. Add query for Region 1:
   - Datasource: `Prometheus-us-east-1`
   - Query: `bdb_used_memory`
   - Legend: `{{bdb}} (Region 1)`
4. Add query for Region 2:
   - Datasource: `Prometheus-us-east-2`
   - Query: `bdb_used_memory`
   - Legend: `{{bdb}} (Region 2)`

Now you can see both regions in one graph! 📊

## Useful Queries

### Check Redis is Up (Both Regions)
```promql
redis_up
```

### Total Requests per Second
```promql
rate(bdb_total_req[5m])
```

### Memory Usage by Database
```promql
bdb_used_memory
```

### Active-Active Replication Lag
```promql
bdb_crdt_syncer_ingress_bytes_decompressed
```

### Cross-Region Comparison
Create a panel with:
- Query A (Region 1): `rate(bdb_total_req[5m])`
- Query B (Region 2): `rate(bdb_total_req[5m])`

## Automation: Start Port-Forwards Automatically

Create a script: `~/start-prometheus-forwards.sh`

```bash
#!/bin/bash

# Kill any existing port-forwards
pkill -f "port-forward.*prometheus"

# Start Region 1 port-forward in background
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1 &

# Start Region 2 port-forward in background
kubectl port-forward -n monitoring svc/prometheus 9091:9090 --context region2 &

echo "✅ Port-forwards started:"
echo "   Region 1: http://localhost:9090"
echo "   Region 2: http://localhost:9091"
echo ""
echo "To stop: pkill -f 'port-forward.*prometheus'"
```

Make it executable:
```bash
chmod +x ~/start-prometheus-forwards.sh
```

Run it:
```bash
~/start-prometheus-forwards.sh
```

## Tips & Tricks

### Keep Port-Forwards Running

Port-forwards can disconnect. Use `kubectl` with auto-restart:

```bash
# Install kubefwd (alternative tool)
brew install txn2/tap/kubefwd

# Or use a loop
while true; do
  kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context region1
  echo "Reconnecting..."
  sleep 2
done
```

### Access from Other Machines

If you want team members to access your local Grafana:

```bash
# Edit Grafana config
vim /opt/homebrew/etc/grafana/grafana.ini

# Change:
[server]
http_addr = 0.0.0.0  # Instead of 127.0.0.1

# Restart
brew services restart grafana
```

Then share: `http://<your-mac-ip>:3000`

### Persistent Dashboards

Grafana stores dashboards in: `/opt/homebrew/var/lib/grafana/grafana.db`

To backup:
```bash
cp /opt/homebrew/var/lib/grafana/grafana.db ~/grafana-backup.db
```

## Comparison: Local vs In-Cluster Grafana

| Feature | Local Grafana | In-Cluster Grafana |
|---------|---------------|-------------------|
| Setup Complexity | ⭐ Simple | ⭐⭐⭐ Complex |
| Performance | ⭐⭐⭐ Fast | ⭐⭐ Network latency |
| Team Access | ❌ No | ✅ Yes |
| Persistence | ✅ Survives cluster rebuilds | ⚠️ Needs PVC |
| Resource Usage | ✅ No cluster resources | ❌ Uses cluster resources |
| Multi-Cluster | ✅ Easy | ⚠️ Complex |
| Updates | ⭐⭐⭐ `brew upgrade` | ⭐⭐ Redeploy |

## Recommendation

**Use Local Grafana if:**
- You're the primary user
- You're in development/testing phase
- You want simplicity
- You monitor multiple environments

**Use In-Cluster Grafana if:**
- Multiple team members need access
- You're in production
- You want 24/7 monitoring
- You have dedicated ops team

For your dual-region Redis Enterprise setup, **local Grafana is perfect!** 🎯

