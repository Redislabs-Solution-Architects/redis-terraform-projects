# Memtier-Based Benchmarking

Load testing and performance benchmarking tools for Redis Enterprise databases using `memtier_benchmark`.

---

## 🎯 Overview

This directory contains Kubernetes Job manifests for running `memtier_benchmark` load tests against:
- **Active-Active CRDB** (multi-region databases)
- **Standard Redis databases** (single-region)

---

## 📋 Available Tests

### 1. Active-Active CRDB Load Test

**File:** `memtier-load-test-job.yaml`

**Configuration:**
- 8 parallel pods (indexed completion)
- ~180K ops/sec total load (configurable)
- 70% reads / 30% writes
- 256-byte payload
- Unique key ranges per pod (no overlap)
- 5-minute test duration
- Database service name is configurable via `CRDB_NAME`
- Database port auto-discovers from the Kubernetes Service when available

**Usage:**
```bash
# Deploy load test with the interactive helper
./run-memtier-job.sh

# Or apply the manifest directly when the defaults are correct
kubectl apply -f memtier-load-test-job.yaml --context region1

# Watch pods
kubectl get pods -l job-name=memtier-load-test -n redis-enterprise -w --context region1

# View results
kubectl logs -l job-name=memtier-load-test -n redis-enterprise --tail=-1 --context region1 | grep "Totals"

# Cleanup
kubectl delete job memtier-load-test -n redis-enterprise --context region1
```

---

## 🔧 Customization

### Adjust Load (ops/sec)

Edit `memtier-load-test-job.yaml`:

```yaml
spec:
  parallelism: 8        # Number of parallel pods (increase for more load)
  completions: 8        # Should match parallelism
```

In the memtier command:
```bash
--clients=50          # Clients per pod (increase for more load)
--threads=4           # Threads per pod (increase for more CPU usage)
--pipeline=1          # Pipeline depth (increase for higher throughput)
--test-time=300       # Test duration in seconds
```

### Target A Different Database

The manifest does not ship with a customer-specific CRDB default. Use the
interactive helper and provide the required values at runtime.

You can also provide the override non-interactively:

```bash
  ./run-memtier-job.sh \
  --manifest memtier-load-test-job.yaml \
  --context <kube-context> \
  --crdb-name <your-crdb-service-name>
```

If Kubernetes cannot auto-discover the service port from the Service env vars,
also set:

```bash
  ./run-memtier-job.sh \
  --manifest memtier-load-test-job.yaml \
  --context <kube-context> \
  --crdb-name <your-crdb-service-name> \
  --redis-port <service-port>
```

`kubectl set env job/...` is not recommended for these one-shot Jobs after
creation because the Job pod template is immutable. If you need different
settings, delete and recreate the Job or use `run-memtier-job.sh`, which does
that for you.

### Adjust Read/Write Ratio

```bash
--ratio=1:3           # 1 SET : 3 GETs (25% writes, 75% reads)
--ratio=3:7           # 3 SETs : 7 GETs (30% writes, 70% reads)
--ratio=1:1           # 50% reads, 50% writes
```

### Adjust Key Pattern

```bash
--key-pattern=R:R     # Random:Random (uniform distribution)
--key-pattern=S:S     # Sequential:Sequential (sequential access)
--key-pattern=P:P     # Parallel:Parallel (each client gets unique range)
```

### Adjust Data Size

```bash
--data-size=256       # Fixed 256 bytes
--data-size-range=100-1024  # Random size between 100-1024 bytes
```

---

## 📊 Understanding Results

### Sample Output

```
Type         Ops/sec     Hits/sec   Misses/sec    Avg. Latency     p50 Latency     p99 Latency
------------------------------------------------------------------------
Sets        45000.00          ---          ---         1.23 msec       1.10 msec       3.50 msec
Gets       135000.00    120000.00    15000.00         1.15 msec       1.05 msec       3.20 msec
Waits           0.00          ---          ---             ---             ---             ---
Totals     180000.00    120000.00    15000.00         1.17 msec       1.07 msec       3.30 msec
```

### Key Metrics

- **Ops/sec**: Operations per second (throughput)
- **Hits/sec**: Cache hits (for GET operations)
- **Misses/sec**: Cache misses (keys not found)
- **Avg. Latency**: Average response time
- **p50/p99 Latency**: 50th/99th percentile latency

### Hit Rate Calculation

```
Hit Rate = Hits / (Hits + Misses) × 100%
Example: 120000 / (120000 + 15000) = 88.9%
```

---

## 🎯 Load Test Scenarios

### Scenario 1: Maximum Throughput Test

**Goal:** Find maximum ops/sec the database can handle

```yaml
parallelism: 12       # More pods
--clients=100         # More clients per pod
--threads=8           # More threads per pod
--pipeline=10         # Higher pipeline depth
--test-time=600       # Longer test (10 minutes)
```

### Scenario 2: Latency Test

**Goal:** Measure latency under controlled load

```yaml
parallelism: 4        # Fewer pods
--clients=25          # Fewer clients
--threads=2           # Fewer threads
--pipeline=1          # No pipelining
--test-time=300       # 5 minutes
```

### Scenario 3: Write-Heavy Workload

**Goal:** Test write performance

```yaml
--ratio=1:1           # 50% writes
--data-size=1024      # Larger payloads
--key-pattern=R:R     # Random keys
```

### Scenario 4: Read-Heavy Workload

**Goal:** Test cache hit performance

```yaml
--ratio=1:9           # 90% reads
--key-pattern=R:R     # Random keys
--key-maximum=100000  # Smaller keyspace (higher hit rate)
```

---

## 🔍 Monitoring During Tests

### Watch Pod Status

```bash
kubectl get pods -l job-name=memtier-load-test -n redis-enterprise -w --context region1
```

### Stream Logs (Real-time)

```bash
kubectl logs -f -l job-name=memtier-load-test -n redis-enterprise --context region1
```

### Check Database Metrics

```bash
# If Prometheus is deployed
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 --context region1

# Open: http://localhost:9090
# Query: rate(bdb_total_req[1m])
```

---

## 🧹 Cleanup

### Delete Completed Job

```bash
kubectl delete job memtier-load-test -n redis-enterprise --context region1
```

### Delete All Memtier Jobs

```bash
kubectl delete jobs -l app=memtier-benchmark -n redis-enterprise --context region1
```

### Auto-Cleanup (TTL)

Jobs are configured with `ttlSecondsAfterFinished: 3600` (1 hour), so they auto-delete after completion.

---

## 📚 Additional Resources

- [memtier_benchmark Documentation](https://github.com/RedisLabs/memtier_benchmark)
- [Redis Enterprise Performance Tuning](https://docs.redis.com/latest/rs/databases/configure/performance/)
- [Kubernetes Jobs Documentation](https://kubernetes.io/docs/concepts/workloads/controllers/job/)

---

## 🆘 Troubleshooting

### Pods Stuck in Pending

```bash
# Check pod events
kubectl describe pod -l job-name=memtier-load-test -n redis-enterprise --context region1

# Common causes:
# - Insufficient cluster resources (CPU/memory)
# - Node affinity rules preventing scheduling
```

### Connection Refused Errors

```bash
# Verify database service
kubectl get svc -n redis-enterprise --context region1

# Check database status
kubectl get redb -n redis-enterprise --context region1

# Verify REDIS_HOST and REDIS_PORT in the Job manifest
```

### Low Throughput

```bash
# Increase parallelism
parallelism: 12

# Increase clients/threads
--clients=100
--threads=8

# Increase pipeline depth
--pipeline=10

# Check database resource limits
kubectl describe redb <database-name> -n redis-enterprise --context region1
```

---

## 🎓 Best Practices

1. **Start Small**: Begin with low parallelism and gradually increase
2. **Monitor Resources**: Watch cluster CPU/memory during tests
3. **Use Realistic Data**: Match production data sizes and patterns
4. **Test Different Scenarios**: Read-heavy, write-heavy, mixed workloads
5. **Run Multiple Times**: Average results across multiple runs
6. **Clean Up**: Delete jobs after completion to free resources
7. **Document Results**: Keep a log of test configurations and results

---

## 📝 Example Test Plan

```bash
# 1. Baseline test (low load)
kubectl apply -f memtier-load-test-job.yaml --context region1
# Wait for completion, record results

# 2. Increase load (2x)
# Edit: parallelism: 16
kubectl apply -f memtier-load-test-job.yaml --context region1
# Wait for completion, record results

# 3. Maximum load test (4x)
# Edit: parallelism: 32, clients: 100
kubectl apply -f memtier-load-test-job.yaml --context region1
# Wait for completion, record results

# 4. Analyze results and determine optimal configuration
```
