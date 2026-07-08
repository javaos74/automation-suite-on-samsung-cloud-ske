# Phase 8: Verification & Monitoring

This guide covers post-deployment verification, health checks, and ongoing monitoring of UiPath Automation Suite on Samsung Cloud SKE.

## Prerequisites

| Item | Requirement |
|------|-------------|
| Deployment | `uipathctl manifest apply` completed (Phase 7) |
| ArgoCD | All applications synced |
| DNS | FQDN resolvable externally |
| Browser | Access to `https://<FQDN>` |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"
export ARGOCD_HOST="alm.${FQDN}"
```

---

## Step 8-1: Check ArgoCD App Sync Status

All ArgoCD applications should show **Synced** and **Healthy** status.

```bash
# List all applications with status
kubectl get applications -n argocd

# Check for any non-healthy applications
kubectl get applications -n argocd -o custom-columns=\
NAME:.metadata.name,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status,\
MESSAGE:.status.conditions[0].message

# Expected: All should show "Synced" and "Healthy"
# Count summary
echo "=== Application Status Summary ==="
echo "Total: $(kubectl get applications -n argocd --no-headers | wc -l)"
echo "Synced: $(kubectl get applications -n argocd --no-headers | grep -c 'Synced')"
echo "Healthy: $(kubectl get applications -n argocd --no-headers | grep -c 'Healthy')"
echo "Degraded: $(kubectl get applications -n argocd --no-headers | grep -c 'Degraded')"
echo "Progressing: $(kubectl get applications -n argocd --no-headers | grep -c 'Progressing')"
```

### Fix OutOfSync Applications

```bash
# If an application is stuck OutOfSync, force sync via ArgoCD
argocd app sync <app-name>

# Or using kubectl
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"operation": {"sync": {"force": true}}}'
```

---

## Step 8-2: Check All Pods Are Running

```bash
# Get pod status summary
echo "=== Pod Status in uipath namespace ==="
kubectl get pods -n uipath --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn

# List non-Running pods (excluding Completed jobs)
kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check for pods in CrashLoopBackOff
kubectl get pods -n uipath | grep -E "CrashLoop|Error|ImagePull"

# Check pods in Pending state
PENDING_PODS=$(kubectl get pods -n uipath --field-selector=status.phase=Pending --no-headers)
if [ -n "${PENDING_PODS}" ]; then
  echo "=== Pending Pods ==="
  echo "${PENDING_PODS}"
  echo ""
  echo "=== Pending Pod Events ==="
  for pod in $(echo "${PENDING_PODS}" | awk '{print $1}'); do
    echo "--- ${pod} ---"
    kubectl describe pod ${pod} -n uipath | grep -A 5 "Events:"
  done
fi
```

### Handle Pending Pods

| Cause | Resolution |
|-------|------------|
| Insufficient CPU/Memory | Add worker nodes or increase node pool |
| PVC Pending | Check StorageClass and CSI driver |
| Node affinity mismatch | Check labels (e.g., `serverless.daemon=true` for ASRobots) |
| Taint not tolerated | Check tolerations in pod spec |

```bash
# Detailed pod diagnosis
kubectl describe pod <pod-name> -n uipath | tail -30

# Check resource requests vs available
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"
```

---

## Step 8-3: Run `uipathctl health check`

```bash
# Run comprehensive health check
uipathctl health check

# With detailed output
uipathctl health check --log-level debug

# Generate support bundle (if issues found)
uipathctl health bundle input-ske.json --versions versions.json
```

### Expected Health Check Output

All checks should pass:
- Database connectivity
- Redis connectivity
- Object storage access
- Certificate validity
- Service endpoints responding
- Pod health

---

## Step 8-4: Access Automation Suite via Browser

```bash
echo "======================================"
echo "  UiPath Automation Suite Access"
echo "======================================"
echo ""
echo "URL: https://${FQDN}"
echo "Username: admin"
echo "Password: (from input-ske.json admin_password)"
echo ""
echo "======================================"
```

### Verify HTTPS

```bash
# Test HTTPS connectivity
curl -vk https://${FQDN} 2>&1 | grep "HTTP/"
# Expected: HTTP/2 200 or HTTP/1.1 302 (redirect to login)

# Check certificate
curl -vk https://${FQDN} 2>&1 | grep "subject:"
# Expected: subject: CN=ske.myrobots.co.kr

# Test login endpoint
curl -sk https://${FQDN}/identity_/.well-known/openid-configuration | python3 -m json.tool | head -10
```

---

## Step 8-5: Access ArgoCD via Browser

```bash
echo "======================================"
echo "  ArgoCD Access"
echo "======================================"
echo ""
echo "URL: https://alm.${FQDN}"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "======================================"
```

### Verify ArgoCD Access

```bash
# Test ArgoCD endpoint
curl -sk https://alm.${FQDN} | grep -i "argocd"

# If not accessible via NLB, use port-forward as fallback
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## Step 8-6: Create Organization and Verify Login

1. Open browser: `https://${FQDN}`
2. Log in with host admin credentials
3. Navigate to **Administration > Organizations**
4. Create a new organization
5. Add users and assign licenses
6. Verify login with new user credentials

### Verify via API

```bash
# Get access token
TOKEN=$(curl -sk https://${FQDN}/identity_/connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<client-id>&client_secret=<client-secret>&scope=OR.Default" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Test Orchestrator API
curl -sk https://${FQDN}/orchestrator_/api/Status/Get \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool
```

---

## Step 8-7: Monitoring Scripts

Use the monitoring script for ongoing health checks:

```bash
# Make executable
chmod +x monitoring-scripts.sh

# Run full health check
./monitoring-scripts.sh health

# Check specific pod logs
./monitoring-scripts.sh logs <pod-name>

# Watch events
./monitoring-scripts.sh events

# Resource usage
./monitoring-scripts.sh resources
```

### Quick Monitoring Commands

```bash
# Pod status overview
kubectl get pods -n uipath -o wide --sort-by='.status.startTime'

# Resource consumption
kubectl top pods -n uipath --sort-by=memory | head -20

# Node resource usage
kubectl top nodes

# Recent events (last 30 minutes)
kubectl get events -n uipath --sort-by='.lastTimestamp' \
  --field-selector type=Warning | tail -20

# PVC status
kubectl get pvc -n uipath

# Service endpoints
kubectl get endpoints -n uipath | head -20
```

---

## Step 8-8: Troubleshooting Guide

### Common Issues and Resolutions

#### Issue: Identity Server 503

```bash
# Check identity pods
kubectl get pods -n uipath -l app=identity

# Check identity logs
kubectl logs -n uipath -l app=identity --tail=30

# Verify SQL connectivity from identity pod
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=identity -o jsonpath='{.items[0].metadata.name}') \
  -- curl -v telnet://${SQL_HOST}:1433
```

#### Issue: Orchestrator CrashLoopBackOff

```bash
# Check orchestrator logs
kubectl logs -n uipath -l app=orchestrator --tail=50 --previous

# Common causes:
# - SQL connection string wrong
# - Redis connection failed
# - Certificate trust issue
```

#### Issue: ASRobot Pods Pending

```bash
# Check node labels
kubectl get nodes --show-labels | grep serverless

# Check tolerations on ASRobot pods
kubectl get pods -n uipath -l app=asrobots -o yaml | grep -A 5 tolerations

# Verify CSI on tainted nodes
kubectl get pods -n kube-system -l app=csi-bs-node -o wide
```

#### Issue: ImagePullBackOff

```bash
# Get image details
kubectl describe pod <pod-name> -n uipath | grep "Image:"

# Check if image exists in offline registry
# docker pull ${TARGET_REGISTRY}/<image-path>

# Check imagePullSecrets
kubectl get pod <pod-name> -n uipath -o jsonpath='{.spec.imagePullSecrets}'
```

#### Issue: PVC Stuck in Pending

```bash
# Check PVC events
kubectl describe pvc <pvc-name> -n uipath

# Verify StorageClass
kubectl get sc

# Check CSI controller logs
kubectl logs -n kube-system -l app=csi-bs-controller --tail=20
```

#### Issue: VirtualService Not Routing

```bash
# Check VirtualService configuration
kubectl get vs -n uipath

# Check Istio proxy logs
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=30

# Verify Gateway resource
kubectl get gateway -n uipath
kubectl describe gateway main-gateway -n uipath
```

#### Issue: Cross-Service Communication Failing (401/503)

```bash
# This usually means FQDN not resolvable from within cluster
# Verify CoreDNS configuration
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=orchestrator -o jsonpath='{.items[0].metadata.name}') \
  -- nslookup ${FQDN}

# Check identity server is responding
curl -sk https://${FQDN}/identity_/.well-known/openid-configuration

# Check certificate trust
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=orchestrator -o jsonpath='{.items[0].metadata.name}') \
  -- curl -v https://${FQDN}/identity_/.well-known/openid-configuration
```

---

## Ongoing Monitoring Checklist

| Check | Frequency | Command |
|-------|-----------|---------|
| Pod health | Every 5 min | `kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded` |
| ArgoCD sync | Every 10 min | `kubectl get applications -n argocd` |
| Node resources | Every 15 min | `kubectl top nodes` |
| Events/Warnings | Every 10 min | `kubectl get events -n uipath --field-selector type=Warning` |
| Certificate expiry | Weekly | `openssl x509 -in tls.crt -noout -enddate` |
| PVC usage | Daily | `kubectl get pvc -n uipath` |
| Health check | Daily | `uipathctl health check` |

---

## Reference

- [UiPath Automation Suite Troubleshooting](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
- [UiPath Health Check](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
