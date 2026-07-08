# Phase 6: ArgoCD Installation + NLB Sharing

This guide covers installing ArgoCD on Samsung Cloud SKE and configuring it to share the Istio Ingress Gateway NLB for external access.

## Prerequisites

| Item | Requirement |
|------|-------------|
| Istio | Installed with NLB working (Phase 5) |
| TLS Certificate | Wildcard cert covering `*.${FQDN}` |
| Offline Registry | ArgoCD chart and images mirrored (Phase 1) |
| DNS | `alm.${FQDN}` resolving to Public IP (Phase 3) |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export ARGOCD_HOST="alm.${FQDN}"
export TARGET_REGISTRY="<samsung-cloud-registry-url>"
export ARGOCD_VERSION="10.1.1"
```

---

## Step 6-1: Install ArgoCD via Helm

Install ArgoCD from the offline registry with ClusterIP service type (NLB access is handled via Istio VirtualService).

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD from offline registry
helm install argocd \
  oci://${TARGET_REGISTRY}/helm/argo/argo-cd \
  --version ${ARGOCD_VERSION} \
  -n argocd \
  -f argocd-values.yaml \
  --wait
```

### Verify ArgoCD Installation

```bash
# Check all ArgoCD pods are running
kubectl get pods -n argocd
# Expected pods:
# argocd-application-controller-xxxxx   1/1   Running
# argocd-repo-server-xxxxx              1/1   Running
# argocd-server-xxxxx                   1/1   Running
# argocd-redis-xxxxx                    1/1   Running
# argocd-dex-server-xxxxx               1/1   Running

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""

# Verify ArgoCD server service
kubectl get svc argocd-server -n argocd
# TYPE should be ClusterIP
```

---

## Step 6-2: Create UiPath AppProject

Create a dedicated ArgoCD AppProject for UiPath applications.

```bash
kubectl apply -f argocd-appproject.yaml
```

### Verify AppProject

```bash
# Check AppProject was created
kubectl get appproject uipath -n argocd

# Describe project details
kubectl describe appproject uipath -n argocd
```

---

## Step 6-3: Create ArgoCD VirtualService (NLB Sharing)

Instead of creating a separate LoadBalancer service for ArgoCD, share the existing Istio Ingress Gateway NLB via a VirtualService.

### Create Gateway Resource

The Gateway is typically created by UiPath's `network-configure` component, but if needed before installation:

```bash
# Check if main-gateway already exists
kubectl get gateway main-gateway -n uipath 2>/dev/null

# If not, the VirtualService will reference it after UiPath deployment
# For pre-deployment ArgoCD access, use port-forward instead:
# kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Apply VirtualService

```bash
kubectl apply -f argocd-virtualservice.yaml
```

### Verify VirtualService

```bash
# Check VirtualService is created
kubectl get virtualservice argocd-vs -n argocd

# Verify routing configuration
kubectl get virtualservice argocd-vs -n argocd -o yaml
```

---

## Step 6-4: Connect OCI Registry to ArgoCD

Connect the Samsung Cloud private registry to ArgoCD as a Helm OCI repository source.

### Option A: Via ArgoCD CLI

```bash
# Install ArgoCD CLI (on jump server)
# Download from: https://github.com/argoproj/argo-cd/releases

# Login to ArgoCD (via port-forward initially)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

argocd login localhost:8080 --username admin --password "${ARGOCD_PASSWORD}" --insecure

# Add OCI repository
argocd repo add ${TARGET_REGISTRY} \
  --type helm \
  --name samsung-registry \
  --enable-oci \
  --username ${REGISTRY_USERNAME} \
  --password ${REGISTRY_PASSWORD} \
  --project uipath
```

### Option B: Via Kubernetes Secret

```bash
# Create repository secret directly
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: uipath-oci-registry
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  name: samsung-cloud-registry
  type: helm
  url: ${TARGET_REGISTRY}
  enableOCI: "true"
  username: ${REGISTRY_USERNAME}
  password: ${REGISTRY_PASSWORD}
  project: uipath
EOF
```

### Verify Repository Connection

```bash
# Check repository is connected
argocd repo list

# Or check via kubectl
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository
```

---

## Step 6-5: Configure RBAC (If Not Using Cluster-Admin)

If you're using restricted permissions instead of cluster-admin, grant the necessary RBAC bindings.

```bash
# Create roles for ArgoCD namespace access
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argo-secret-role
  namespace: argocd
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["*"]
  - apiGroups: ["*"]
    resources: ["secrets"]
    verbs: ["get", "watch", "list", "patch", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: uipath-application-manager
  namespace: argocd
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["*"]
EOF

# Bind roles to service account
kubectl -n argocd create rolebinding secret-binding \
  --role=argo-secret-role --serviceaccount=uipath:uipathadmin

kubectl -n argocd create rolebinding uipath-application-manager-rolebinding \
  --role=uipath-application-manager --serviceaccount=uipath:uipathadmin
```

> **Note:** If using Cluster Admin privileges (as recommended for dedicated clusters), skip this step.

---

## Step 6-6: Verify ArgoCD UI Accessible via `alm.<FQDN>`

### Pre-UiPath Deployment (Port Forward)

Before UiPath is deployed and the Gateway resource exists:

```bash
# Port-forward to access ArgoCD locally
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access via browser: https://localhost:8080
# Username: admin
# Password: (from Step 6-1)
```

### Post-UiPath Deployment (via NLB)

After UiPath is deployed and the `main-gateway` exists:

```bash
# Verify VirtualService is routing correctly
curl -vk https://alm.${FQDN} 2>&1 | grep "HTTP/"
# Expected: HTTP/2 200 or HTTP/1.1 200

# Access via browser
echo "ArgoCD URL: https://alm.${FQDN}"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

---

## Architecture: NLB Sharing

```
                          ┌─────────────────────────────┐
                          │  Samsung Cloud NLB           │
                          │  Public IP: 123.41.32.188   │
                          │  Ports: 80, 443             │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │  Istio Ingress Gateway      │
                          │  (NodePort Service)         │
                          └──────────────┬──────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                     │
         ┌──────────▼──────────┐  ┌─────▼─────┐  ┌──────────▼──────────┐
         │ Host: ske.myrobots  │  │Host: alm.  │  │ Host: *.ske.myro... │
         │ → UiPath Services   │  │→ ArgoCD    │  │ → Other Services    │
         │ (VirtualServices)   │  │(VS: argocd │  │ (VirtualServices)   │
         └─────────────────────┘  │    -vs)    │  └─────────────────────┘
                                  └────────────┘
```

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| ArgoCD pods running | `kubectl get pods -n argocd` | All Running |
| ArgoCD server ClusterIP | `kubectl get svc argocd-server -n argocd` | ClusterIP type |
| AppProject created | `kubectl get appproject uipath -n argocd` | Exists |
| VirtualService created | `kubectl get vs argocd-vs -n argocd` | Exists |
| Registry connected | `argocd repo list` | samsung-cloud-registry connected |
| UI accessible | `curl -k https://alm.${FQDN}` | HTTP 200 |

---

## Troubleshooting

### ArgoCD UI Not Accessible via NLB

```bash
# Check VirtualService is attached to correct gateway
kubectl get vs argocd-vs -n argocd -o jsonpath='{.spec.gateways}'

# Check the gateway exists
kubectl get gateway main-gateway -n uipath

# Check Istio proxy logs for routing errors
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=20 | grep "alm"

# Fallback: use port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### ArgoCD Cannot Pull from OCI Registry

```bash
# Check repository secret
kubectl get secret uipath-oci-registry -n argocd -o yaml

# Check ArgoCD repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --tail=30

# Test registry access from cluster
kubectl run reg-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" https://${TARGET_REGISTRY}/v2/_catalog
```

### Application Sync Failures

```bash
# Check application status
kubectl get applications -n argocd

# Describe failing application
kubectl describe application <app-name> -n argocd

# Check ArgoCD application controller logs
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller --tail=50
```

---

## Reference

- [ArgoCD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [ArgoCD OCI Repository](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#oci-registries)
- [UiPath ArgoCD Configuration](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
