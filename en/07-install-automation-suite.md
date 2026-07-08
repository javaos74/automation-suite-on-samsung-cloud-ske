# Phase 7: UiPath Automation Suite Installation

This guide covers the actual deployment of UiPath Automation Suite on Samsung Cloud SKE using `uipathctl`.

## Prerequisites

| Item | Requirement |
|------|-------------|
| Istio | Installed with NLB and TLS (Phase 5) |
| ArgoCD | Installed with registry connected (Phase 6) |
| Storage | Block and NFS storage ready (Phase 4) |
| External Deps | SQL Server, Redis, Object Storage accessible |
| uipathctl | Binary installed on admin machine |
| input.json | Prepared with SKE-specific configuration |
| versions.json | UiPath version manifest file |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"
export WORK_DIR="/opt/uipath-install"
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
```

---

## Step 7-1: Create Namespaces

Three namespaces are required. Two should already exist from earlier phases:

| Namespace | Created In | Purpose |
|-----------|-----------|---------|
| `istio-system` | Phase 5 (Step 5-1) | Istio control plane and ingress gateway |
| `argocd` | Phase 6 (Step 6-1) | ArgoCD GitOps engine |
| `uipath` | **This step** | UiPath Automation Suite services |

```bash
# Verify namespaces from previous phases exist
kubectl get ns istio-system   # Created in Phase 5, Step 5-1
kubectl get ns argocd         # Created in Phase 6, Step 6-1

# Create uipath namespace (new in this phase)
kubectl create ns uipath

# Verify all three namespaces
kubectl get ns istio-system argocd uipath
```

> **Note:** If `istio-system` or `argocd` namespaces are missing, revisit Phase 5 or Phase 6 respectively. Do not skip those phases.

---

## Step 7-2: Apply ResourceQuotas for Priority Classes

SKE may enforce resource quotas for namespaces using system-critical priority classes. Apply quotas to prevent pod scheduling failures.

```bash
kubectl apply -f resource-quotas.yaml
```

### Verify Quotas

```bash
# Check quotas in each namespace
kubectl get resourcequota -n istio-system
kubectl get resourcequota -n argocd
kubectl get resourcequota -n uipath
```

---

## Step 7-3: Configure CoreDNS for In-Cluster FQDN Resolution

UiPath Automation Suite requires that the FQDN resolves from within cluster pods. All inter-service communication uses the external FQDN (hairpin pattern).

### Check Current CoreDNS Configuration

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

### Apply Custom CoreDNS Configuration

```bash
kubectl apply -f coredns-custom-config.yaml
```

### Restart CoreDNS

```bash
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns
```

---

## Step 7-4: Verify In-Cluster DNS Resolution

> **Critical:** Run this BEFORE proceeding to `manifest apply`. If DNS resolution fails from within pods, all cross-service communication will break at runtime.

```bash
# Test base FQDN resolution
kubectl run dns-test --rm -it --image=busybox --restart=Never -- \
  nslookup ${FQDN}
# Expected: Name: ske.myrobots.co.kr  Address: 123.41.32.188

# Test wildcard subdomain resolution
kubectl run dns-test2 --rm -it --image=busybox --restart=Never -- \
  nslookup alm.${FQDN}
# Expected: Name: alm.ske.myrobots.co.kr  Address: 123.41.32.188

# Test from a long-running pod (more reliable)
kubectl run dns-debug --image=busybox --restart=Never -- sleep 3600
kubectl exec dns-debug -- nslookup ${FQDN}
kubectl exec dns-debug -- nslookup alm.${FQDN}
kubectl delete pod dns-debug
```

Both must resolve to the Public IP (`123.41.32.188`). If not, revisit the CoreDNS configuration.

---

## Step 7-5: Prepare input.json

The `input.json` file is the central configuration for UiPath Automation Suite deployment. Use `input-ske.json` as the final configuration.

### Key SKE-Specific Settings

```json
{
  "registries": {
    "docker": { "url": "<samsung-cloud-registry-url>" },
    "helm": { "url": "<samsung-cloud-registry-url>" }
  },
  "fqdn": "ske.myrobots.co.kr",
  "namespace": "uipath",
  "cluster_type": "exclusive",
  "kubernetes_distribution": "vanilla",
  "storage_class": "bs-ssd",
  "storage_class_single_replica": "bs-ssd",
  "storage_class_name_with_rwx_support": "nfs-subdir-external-sc",
  "exclude_components": [
    "monitoring", "argocd", "logging", "gatekeeper",
    "dapr", "velero", "alerts", "network-policies",
    "cert-manager", "istio"
  ],
  "ingress": {
    "namespace": "istio-system",
    "gateway_selector": { "istio": "ingressgateway" },
    "ingress_gateway_secret": "istio-ingressgateway-certs",
    "istio_gateway_service_name": "istio-ingressgateway"
  },
  "argocd": {
    "application_namespace": "argocd",
    "project": "uipath"
  }
}
```

### Validate input.json

```bash
# Check JSON syntax
python3 -m json.tool input-ske.json > /dev/null
echo "JSON syntax OK"

# Verify key fields
python3 -c "
import json
with open('input-ske.json') as f:
    cfg = json.load(f)
print(f'FQDN: {cfg[\"fqdn\"]}')
print(f'Namespace: {cfg[\"namespace\"]}')
print(f'Profile: {cfg[\"profile\"]}')
print(f'Cluster Type: {cfg[\"cluster_type\"]}')
print(f'Storage RWO: {cfg[\"storage_class\"]}')
print(f'Storage RWX: {cfg[\"storage_class_name_with_rwx_support\"]}')
print(f'Excluded: {cfg[\"exclude_components\"]}')
"
```

---

## Step 7-6: Run `uipathctl prereq create`

This command creates the required databases in SQL Server and buckets in Object Storage.

```bash
uipathctl prereq create input-ske.json \
  --versions versions.json \
  --log-level debug
```

### Expected Output

- Creates databases for each enabled service (Orchestrator, Platform, AI Center, etc.)
- Creates object storage buckets
- Takes 5-10 minutes

### Handle CORS Errors

If the command fails with CORS-related errors for object storage:

```bash
# Samsung Cloud Object Storage may not support put-bucket-cors via S3 API
# Configure CORS manually via Samsung Cloud Console:
# 1. Navigate to Storage > Object Storage > Bucket > CORS Settings
# 2. Add CORS rule:
#    - AllowedOrigins: https://ske.myrobots.co.kr
#    - AllowedMethods: GET, HEAD, PUT, POST, DELETE
#    - AllowedHeaders: *
#    - MaxAgeSeconds: 3000
```

### Verify Database Creation

```bash
# Connect to SQL Server and list databases
kubectl run sql-check --rm -it --image=mcr.microsoft.com/mssql-tools:latest --restart=Never -- \
  /opt/mssql-tools/bin/sqlcmd -S ${SQL_HOST},${SQL_PORT} -U ${SQL_USER} -P "${SQL_PASSWORD}" \
  -Q "SELECT name FROM sys.databases WHERE name LIKE 'AutomationSuite%'"
```

---

## Step 7-7: Run `uipathctl prereq run`

Validate all prerequisites are met before deployment.

```bash
uipathctl prereq run input-ske.json \
  --versions versions.json \
  --log-level debug
```

### Handle DNS Check Failures

If local DNS check fails (common for internal domains):

```bash
# Skip local DNS check (in-cluster DNS was already verified in Step 7-4)
uipathctl prereq run input-ske.json \
  --versions versions.json \
  --log-level debug \
  --excluded "DNS(fqdn=alm.${FQDN})"
```

### Expected Checks

| Check | Description |
|-------|-------------|
| SQL connectivity | Connects to SQL Server |
| Redis connectivity | Connects to Redis with TLS |
| Object Storage | Verifies bucket access |
| Storage Classes | Validates RWO and RWX classes exist |
| Certificate | Validates TLS secret |
| DNS | Resolves FQDN (may fail locally for internal domains) |
| Kubernetes version | Checks compatibility |

All checks should pass (except possibly local DNS for internal domains).

---

## Step 7-8: Run `uipathctl manifest apply`

Deploy UiPath Automation Suite.

```bash
uipathctl manifest apply input-ske.json \
  --versions versions.json
```

### Expected Behavior

1. Creates ArgoCD Applications for each UiPath component
2. ArgoCD syncs Helm charts from the OCI registry
3. Pods begin deploying in the `uipath` namespace
4. Process takes **30-60 minutes** depending on enabled services

### Monitor Progress

Open a second terminal to monitor:

```bash
# Watch ArgoCD application status
watch -n 10 "kubectl get applications -n argocd"

# Watch pod deployment progress
watch -n 10 "kubectl get pods -n uipath --sort-by=.status.phase | tail -30"

# Count pods by status
watch -n 10 "echo 'Running:' && kubectl get pods -n uipath --field-selector=status.phase=Running --no-headers | wc -l && echo 'Pending:' && kubectl get pods -n uipath --field-selector=status.phase=Pending --no-headers | wc -l"
```

---

## Step 7-9: Monitor via ArgoCD UI and kubectl

### ArgoCD UI Monitoring

```bash
# Access ArgoCD UI
# If VirtualService is working:
echo "ArgoCD URL: https://alm.${FQDN}"

# Otherwise, port-forward:
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
```

In ArgoCD UI:
- All applications should show **Synced** status
- Health should be **Healthy** (may take time for initial deployment)
- Check individual applications for errors

### kubectl Monitoring

```bash
# Overall status
kubectl get pods -n uipath -o wide

# Check for failing pods
kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check events for issues
kubectl get events -n uipath --sort-by='.lastTimestamp' | tail -20

# Check specific pod issues
kubectl describe pod <pod-name> -n uipath

# View container logs for failing pods
kubectl logs <pod-name> -n uipath -c <container-name> --tail=50
```

### Wait for Completion

```bash
# Wait until all applications are synced and healthy
while true; do
  TOTAL=$(kubectl get applications -n argocd --no-headers | wc -l)
  HEALTHY=$(kubectl get applications -n argocd --no-headers | grep -c "Healthy")
  SYNCED=$(kubectl get applications -n argocd --no-headers | grep -c "Synced")
  echo "$(date): Applications - Total: ${TOTAL}, Healthy: ${HEALTHY}, Synced: ${SYNCED}"
  if [ "${HEALTHY}" -eq "${TOTAL}" ] && [ "${SYNCED}" -eq "${TOTAL}" ]; then
    echo "All applications are Healthy and Synced!"
    break
  fi
  sleep 30
done
```

---

## Post-Deployment Notes

### Services Deployed

After successful deployment, the following ArgoCD applications will be created:

| Application | Description |
|-------------|-------------|
| `orchestrator` | UiPath Orchestrator |
| `platform` | Platform services (Identity, Portal) |
| `aicenter` | AI Center |
| `asrobots` | Automation Suite Robots |
| `ecs` | Enterprise Content Services |
| `studioweb` | Studio Web |
| `maestro` | Maestro (Process Orchestration) |
| `llmgateway` | LLM Gateway |
| `agents` | UiPath Agents |
| `agenthub` | Agent Hub |
| `istio-configure` | Istio routing configuration |
| `network-configure` | Network policies and gateway |

### Common Issues During Deployment

| Issue | Cause | Resolution |
|-------|-------|------------|
| Pod ImagePullBackOff | Image not in offline registry | Mirror missing image |
| Pod Pending (no nodes) | Insufficient resources | Add worker nodes |
| Pod CrashLoopBackOff | Configuration error | Check logs for details |
| PVC Pending | StorageClass issue | Verify CSI and SC |
| ASRobot Pending | Missing label on nodes | Add `serverless.daemon=true` label |

---

## Reference

- [UiPath Installation Guide (EKS/AKS)](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
- [UiPath Sizing Calculator](https://docs.uipath.com/automation-suite/2025.10/calculator)
