# Network Security Configuration for Prometheus Monitoring

This document describes the network security requirements for monitoring Redis Enterprise with Prometheus across namespaces.

## Overview

- **Redis Enterprise Namespace**: `redis-enterprise`
- **Monitoring Namespace**: `monitoring`
- **Metrics Port**: `8070` (HTTPS)
- **Architecture**: Cross-namespace monitoring (Prometheus in `monitoring` namespace scrapes Redis Enterprise in `redis-enterprise` namespace)

## Kubernetes Network Requirements

### 1. Cross-Namespace Communication

By default, Kubernetes allows pod-to-pod communication across namespaces. No additional NetworkPolicies are required unless you have explicitly restricted cross-namespace traffic.

**If you have NetworkPolicies enabled**, you'll need to allow traffic from the `monitoring` namespace to the `redis-enterprise` namespace on port 8070:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scraping
  namespace: redis-enterprise
spec:
  podSelector:
    matchLabels:
      app: redis-enterprise
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 8070
```

### 2. RBAC Permissions

The Prometheus instance needs ClusterRole permissions to discover and scrape ServiceMonitors across namespaces. This is already configured in `02-prometheus-instance.yaml`:

- **ClusterRole**: `prometheus-k8s` - Allows Prometheus to list/get/watch services, endpoints, and pods across all namespaces
- **ClusterRoleBinding**: Binds the ClusterRole to the Prometheus service account

## AWS Security Group Requirements

### EKS Node Security Groups

The EKS node security groups must allow traffic on port 8070 between nodes for Prometheus to scrape Redis Enterprise metrics.

**Required Security Group Rule:**

- **Type**: Custom TCP
- **Protocol**: TCP
- **Port Range**: 8070
- **Source**: Same security group (self-referencing rule)
- **Description**: Redis Enterprise metrics endpoint for Prometheus

### How to Verify

Check if the rule exists:

```bash
# Get the node security group ID
NODE_SG_ID=$(aws eks describe-cluster \
  --name <cluster-name> \
  --region <region> \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

# Check for port 8070 rule
aws ec2 describe-security-groups \
  --group-ids $NODE_SG_ID \
  --region <region> \
  --query 'SecurityGroups[0].IpPermissions[?ToPort==`8070`]'
```

### How to Add (if missing)

```bash
# Add ingress rule for port 8070
aws ec2 authorize-security-group-ingress \
  --group-id $NODE_SG_ID \
  --protocol tcp \
  --port 8070 \
  --source-group $NODE_SG_ID \
  --region <region>
```

**Note**: The Terraform modules in this project should already configure this rule. If you're using the EKS module from this repository, the security group rules are managed automatically.

## Service Discovery Configuration

### ServiceMonitor Configuration

The ServiceMonitor is deployed in the `redis-enterprise` namespace and targets the Redis Enterprise metrics service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-enterprise-metrics
  namespace: redis-enterprise  # Same namespace as Redis Enterprise
spec:
  selector:
    matchLabels:
      app: redis-enterprise
  endpoints:
  - port: metrics  # Port 8070
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
```

### Prometheus Configuration

The Prometheus instance is configured to discover ServiceMonitors across all namespaces:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
  namespace: monitoring
spec:
  serviceMonitorNamespaceSelector: {}  # Empty selector = all namespaces
  serviceMonitorSelector: {}           # Empty selector = all ServiceMonitors
```

## Verification Steps

### 1. Verify Network Connectivity

Test connectivity from a Prometheus pod to the Redis Enterprise metrics endpoint:

```bash
# Get a Prometheus pod name
PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')

# Get Redis Enterprise service IP
REC_SVC=$(kubectl get svc -n redis-enterprise -l app=redis-enterprise -o jsonpath='{.items[0].spec.clusterIP}')

# Test connectivity
kubectl exec -n monitoring $PROM_POD -- curl -k https://$REC_SVC:8070/metrics
```

### 2. Verify ServiceMonitor Discovery

Check if Prometheus has discovered the ServiceMonitor:

```bash
# Port-forward Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open browser to http://localhost:9090/targets
# Look for "redis-enterprise/redis-enterprise-metrics" targets
```

### 3. Verify Metrics Collection

Query Prometheus for Redis Enterprise metrics:

```bash
# Port-forward Prometheus UI (if not already done)
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open browser to http://localhost:9090/graph
# Run query: redis_up
# Should return 1 for each Redis Enterprise cluster
```

## Troubleshooting

### ServiceMonitor Not Discovered

**Symptom**: ServiceMonitor doesn't appear in Prometheus targets

**Solutions**:
1. Verify RBAC permissions: `kubectl get clusterrole prometheus-k8s`
2. Check Prometheus logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus`
3. Verify ServiceMonitor exists: `kubectl get servicemonitor -n redis-enterprise`

### Targets Show as "Down"

**Symptom**: Targets appear in Prometheus but status is "Down"

**Solutions**:
1. Check network connectivity (see verification steps above)
2. Verify port 8070 is open in security groups
3. Check Redis Enterprise service: `kubectl get svc -n redis-enterprise`
4. Verify Redis Enterprise pods are running: `kubectl get pods -n redis-enterprise`

### Certificate Errors

**Symptom**: TLS certificate verification errors in Prometheus logs

**Solution**: The ServiceMonitor is configured with `insecureSkipVerify: true` to bypass certificate validation. This is acceptable for internal cluster communication. For production, consider using proper certificates.

## Security Best Practices

1. **Set a Secure Grafana Password**: Configure a strong `grafana_admin_password` value before enabling in-cluster Grafana
2. **Enable NetworkPolicies**: Restrict traffic to only what's necessary
3. **Use TLS Certificates**: For production, configure proper TLS certificates instead of `insecureSkipVerify`
4. **Limit RBAC Permissions**: Review and restrict Prometheus RBAC permissions to minimum required
5. **Secure Grafana**: Enable authentication, use HTTPS, and configure proper access controls
