# Phase 4: Storage & External Dependencies

This guide covers configuring storage classes and provisioning external dependencies (SQL Server, Redis, Object Storage) for UiPath Automation Suite on Samsung Cloud SKE.

## Prerequisites

| Item | Requirement |
|------|-------------|
| SKE Cluster | Running with all node pools (Phase 2) |
| Network | Firewall rules configured (Phase 3) |
| NFS Server | Provisioned with exported path |
| SQL Server | Provisioned and accessible from cluster |
| Redis | Provisioned with TLS enabled |
| Object Storage | Samsung Cloud Object Storage bucket created |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"

# NFS Server
export NFS_SERVER="<nfs-server-ip>"
export NFS_PATH="/exported/path"

# SQL Server
export SQL_HOST="<sql-server-host>"
export SQL_PORT="1433"
export SQL_USER="uipath"
export SQL_PASSWORD="<sql-password>"

# Redis
export REDIS_HOST="<redis-host>"
export REDIS_PORT="6380"
export REDIS_PASSWORD="<redis-password>"

# Object Storage (Samsung Cloud S3-compatible)
export S3_FQDN="object-store.kr-west1.e.samsungsdscloud.com"
export S3_PORT="443"
export S3_ACCESS_KEY="<access-key>"
export S3_SECRET_KEY="<secret-key>"
export S3_REGION="kr-west1"
```

---

## Step 4-1: Verify Block Storage (bs-ssd)

Samsung Cloud SKE comes with the Block Storage CSI driver pre-installed (`bs.csi.samsungsdscloud.com`).

```bash
# Verify CSI driver is installed
kubectl get csidrivers
# Expected: bs.csi.samsungsdscloud.com

# Verify StorageClasses exist
kubectl get storageclasses
# Expected:
# NAME                           PROVISIONER                    RECLAIMPOLICY
# bs-ssd                         bs.csi.samsungsdscloud.com     Delete
# bs-ssd-retain                  bs.csi.samsungsdscloud.com     Retain

# Test PVC creation
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-bs-ssd
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: bs-ssd
  resources:
    requests:
      storage: 1Gi
EOF

# Verify PVC is bound
kubectl get pvc test-bs-ssd
# STATUS should be "Bound"

# Clean up test PVC
kubectl delete pvc test-bs-ssd
```

---

## Step 4-2: Patch CSI DaemonSet Toleration for Tainted Nodes

The `csi-bs-node` DaemonSet must run on ALL nodes, including tainted ASRobot nodes. Without this patch, PVCs on ASRobot nodes will fail with:
```
no topology key found on CSINode ske-worker-asrobot-*
```

### Apply Patch

```bash
# Method A: Using patch file (recommended)
kubectl patch daemonset csi-bs-node -n kube-system \
  --type merge --patch-file csi-bs-node-toleration-patch.yaml

# Method B: Inline patch
kubectl patch ds csi-bs-node -n kube-system --type merge \
  -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'
```

### Verify Patch

```bash
# 1) DaemonSet should be running on ALL nodes (DESIRED == total worker count)
kubectl get ds csi-bs-node -n kube-system

# 2) Verify pod is running on tainted ASRobot nodes
kubectl get pods -n kube-system -l app=csi-bs-node -o wide | grep asrobot

# 3) Verify CSINode topology key is registered for ASRobot nodes
ASROBOT_NODE=$(kubectl get nodes -l serverless.daemon=true -o jsonpath='{.items[0].metadata.name}')
kubectl get csinode ${ASROBOT_NODE} \
  -o jsonpath='{range .spec.drivers[*]}{.name}{" | "}{.topologyKeys}{"\n"}{end}'
# Expected: bs.csi.samsungsdscloud.com | ["topology.bs.csi.samsungsdscloud.com/zone"]
```

---

## Step 4-3: Install NFS Subdir External Provisioner

UiPath Automation Suite requires ReadWriteMany (RWX) storage for StudioWeb, ECS, and other services. Use NFS for RWX support.

### Install from Offline Registry

```bash
# Login to registry for Helm
helm registry login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}

# Install NFS Provisioner using values file
helm install nfs-provisioner \
  oci://${TARGET_REGISTRY}/helm/nfs/nfs-subdir-external-provisioner \
  --namespace nfs-system \
  --create-namespace \
  -f nfs-provisioner-values.yaml
```

### Verify NFS Provisioner

```bash
# Check provisioner pod is running
kubectl get pods -n nfs-system

# Verify StorageClasses created
kubectl get storageclasses | grep nfs
# Expected:
# nfs-subdir-external-sc          k8s-sigs.io/nfs-subdir-external-provisioner   Delete
# nfs-subdir-external-sc-retain   k8s-sigs.io/nfs-subdir-external-provisioner   Retain

# Test RWX PVC creation
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-rwx
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-subdir-external-sc
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-nfs-rwx
# STATUS should be "Bound"

# Clean up
kubectl delete pvc test-nfs-rwx
```

---

## Step 4-4: Provision SQL Server

UiPath Automation Suite requires Microsoft SQL Server for all product databases.

### Requirements

| Item | Specification |
|------|--------------|
| Version | SQL Server 2019 or 2022 (Standard/Enterprise) |
| vCPU | 8+ (production) |
| Memory | 32 GB+ (production) |
| Storage | 500 GB SSD |
| TLS | Enabled |
| Authentication | SQL Authentication |
| Accessibility | Reachable from SKE worker nodes |

### Verify SQL Server Connectivity

```bash
# From a pod inside the cluster
kubectl run sql-test --rm -it --image=mcr.microsoft.com/mssql-tools:latest --restart=Never -- \
  /opt/mssql-tools/bin/sqlcmd -S ${SQL_HOST},${SQL_PORT} -U ${SQL_USER} -P "${SQL_PASSWORD}" \
  -Q "SELECT @@VERSION"

# Or using a simple TCP test
kubectl run tcp-test --rm -it --image=busybox --restart=Never -- \
  nc -zv ${SQL_HOST} ${SQL_PORT}
```

### SQL Server Connection String Format

```
Server=tcp:<SQL_HOST>,1433;Initial Catalog=DB_NAME_PLACEHOLDER;Persist Security Info=False;User Id=<SQL_USER>;Password='<SQL_PASSWORD>';MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Max Pool Size=100;
```

> **Note:** `DB_NAME_PLACEHOLDER` is replaced automatically by `uipathctl prereq create`.

---

## Step 4-5: Provision Redis

### Requirements

| Item | Specification |
|------|--------------|
| Version | Redis 6.x or 7.x |
| Mode | Standalone or Sentinel (NOT cluster mode) |
| Memory | 4 GB+ (production) |
| TLS | Enabled (port 6380) |
| Authentication | Password required |
| Accessibility | Reachable from SKE worker nodes |

### Verify Redis Connectivity

```bash
# TCP connectivity test from cluster
kubectl run redis-test --rm -it --image=busybox --restart=Never -- \
  nc -zv ${REDIS_HOST} ${REDIS_PORT}

# Full Redis test with TLS
kubectl run redis-test --rm -it --image=redis:7-alpine --restart=Never -- \
  redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} --tls -a "${REDIS_PASSWORD}" PING
# Expected: PONG
```

---

## Step 4-6: Configure Samsung Cloud Object Storage

Samsung Cloud Object Storage provides S3-compatible API access.

### Requirements

| Item | Specification |
|------|--------------|
| Endpoint | `object-store.kr-west1.e.samsungsdscloud.com` |
| Port | 443 (HTTPS) |
| Protocol | S3-compatible API |
| Authentication | Access Key + Secret Key |
| Bucket | Pre-created or auto-create via uipathctl |

### Create Object Storage Bucket

1. Log in to Samsung Cloud Console
2. Navigate to **Storage > Object Storage**
3. Create a bucket (e.g., `as-bucket`)
4. Create access credentials (Access Key + Secret Key)

### Verify Object Storage Connectivity

```bash
# Test from within the cluster using AWS CLI (S3-compatible)
kubectl run s3-test --rm -it --image=amazon/aws-cli:latest --restart=Never -- \
  aws s3 ls \
  --endpoint-url https://${S3_FQDN} \
  --region ${S3_REGION}

# Or test with curl
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -v https://${S3_FQDN}
```

### Configure CORS on Bucket

```bash
# CORS configuration required for browser-based access
aws s3api put-bucket-cors \
  --bucket as-bucket \
  --endpoint-url https://${S3_FQDN} \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["POST", "GET", "HEAD", "DELETE", "PUT"],
      "AllowedOrigins": ["https://'"${FQDN}"'"],
      "ExposeHeaders": ["etag", "x-amz-server-side-encryption", "x-amz-request-id", "x-amz-id-2"],
      "MaxAgeSeconds": 3000
    }]
  }'
```

---

## Step 4-7: Combine CA Certificates

If SQL Server and/or Redis use TLS with private CAs, combine all CA certificates into a single file:

```bash
# Collect CA certificates
# - sql-ca.pem: SQL Server CA certificate
# - redis-ca.pem: Redis CA certificate
# - registry-ca.pem: Samsung Cloud Registry CA (if private)

# Combine into single file
cat sql-ca.pem redis-ca.pem > combined-ca.pem

# Verify combined certificate
openssl x509 -in combined-ca.pem -text -noout | head -20

# Note the path for input.json
echo "Use this path in input.json additional_ca_certs: $(pwd)/combined-ca.pem"
```

> **Note:** If using public CAs (e.g., DigiCert, Let's Encrypt), this step may not be necessary as the system trust store already includes them.

---

## Storage Classes Summary

| Name | Provisioner | Access Mode | Reclaim Policy | Use Case |
|------|-------------|-------------|----------------|----------|
| `bs-ssd` | `bs.csi.samsungsdscloud.com` | RWO | Delete | General persistent volumes |
| `bs-ssd-retain` | `bs.csi.samsungsdscloud.com` | RWO | Retain | Critical data (databases) |
| `nfs-subdir-external-sc` | `k8s-sigs.io/nfs-subdir-external-provisioner` | RWX | Delete | StudioWeb, ECS, shared storage |
| `nfs-subdir-external-sc-retain` | `k8s-sigs.io/nfs-subdir-external-provisioner` | RWX | Retain | Critical shared data |

### Storage Class Mapping in input.json

```json
{
  "storage_class": "bs-ssd",
  "storage_class_single_replica": "bs-ssd",
  "storage_class_name_with_rwx_support": "nfs-subdir-external-sc"
}
```

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| Block Storage CSI | `kubectl get csidrivers` | `bs.csi.samsungsdscloud.com` listed |
| bs-ssd StorageClass | `kubectl get sc bs-ssd` | Available |
| CSI on tainted nodes | `kubectl get pods -n kube-system -l app=csi-bs-node -o wide` | Running on ALL nodes |
| NFS Provisioner running | `kubectl get pods -n nfs-system` | Running |
| NFS StorageClass | `kubectl get sc nfs-subdir-external-sc` | Available |
| SQL connectivity | TCP test from pod | Connection successful |
| Redis connectivity | PING from pod | PONG response |
| Object Storage | S3 list from pod | No errors |
| CA certificates | `openssl x509 -in combined-ca.pem -text` | Certificate info displayed |

---

## Troubleshooting

### PVC Stuck in Pending

```bash
# Check events
kubectl describe pvc <pvc-name>

# Common causes:
# - StorageClass not found → verify name matches
# - CSI not running on node → check csi-bs-node DaemonSet
# - Insufficient disk quota → check Samsung Cloud quotas
```

### NFS Mount Failures

```bash
# Check NFS provisioner logs
kubectl logs -n nfs-system -l app=nfs-subdir-external-provisioner

# Verify NFS server is reachable from nodes
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- \
  ping -c 3 ${NFS_SERVER}

# Check NFS exports on server
showmount -e ${NFS_SERVER}
```

### SQL Connection Refused

```bash
# Verify firewall allows traffic from worker nodes to SQL Server
# Check Security Group rules for SQL Server port (1433)

# Test from multiple nodes
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "Testing from ${node}..."
  kubectl debug node/${node} -it --image=busybox -- nc -zv ${SQL_HOST} ${SQL_PORT}
done
```
