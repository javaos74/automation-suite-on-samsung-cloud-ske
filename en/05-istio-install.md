# Phase 5: Istio Installation + NLB Integration

This guide covers installing Istio service mesh on Samsung Cloud SKE and integrating it with the Samsung Cloud NLB (Network Load Balancer).

## Prerequisites

| Item | Requirement |
|------|-------------|
| SKE Cluster | Running with all node pools (Phase 2) |
| Network/NLB | Firewall rules configured, Public IP allocated (Phase 3) |
| Storage | Block and NFS storage ready (Phase 4) |
| Offline Registry | Istio charts and images mirrored (Phase 1) |
| Helm | v3.8+ installed |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export PUBLIC_IP="123.41.32.188"
export PUBLIC_IP_ID="a5168593ce6c44d68e7255606eb07d14"
export TARGET_REGISTRY="<samsung-cloud-registry-url>"
export ISTIO_VERSION="1.30.2"
```

---

## Step 5-1: Install Istio Base CRDs

Install Istio Custom Resource Definitions from the offline registry.

```bash
# Create istio-system namespace
kubectl create namespace istio-system

# Install Istio base CRDs from offline registry
helm install istio-base \
  oci://${TARGET_REGISTRY}/helm/istio/base \
  --version ${ISTIO_VERSION} \
  -n istio-system \
  --set defaultRevision=default
```

### Verify CRDs

```bash
# Check Istio CRDs are installed
kubectl get crds | grep istio
# Expected CRDs:
# authorizationpolicies.security.istio.io
# destinationrules.networking.istio.io
# envoyfilters.networking.istio.io
# gateways.networking.istio.io
# peerauthentications.security.istio.io
# requestauthentications.security.istio.io
# serviceentries.networking.istio.io
# sidecars.networking.istio.io
# virtualservices.networking.istio.io
# workloadentries.networking.istio.io
# workloadgroups.networking.istio.io
```

---

## Step 5-2: Install istiod Control Plane

```bash
# Install istiod from offline registry
helm install istiod \
  oci://${TARGET_REGISTRY}/helm/istio/istiod \
  --version ${ISTIO_VERSION} \
  -n istio-system \
  --set pilot.image="${TARGET_REGISTRY}/istio/pilot:${ISTIO_VERSION}" \
  --set global.proxy.image="${TARGET_REGISTRY}/istio/proxyv2:${ISTIO_VERSION}" \
  --set global.hub="${TARGET_REGISTRY}/istio" \
  --set global.tag="${ISTIO_VERSION}" \
  --wait
```

### Verify istiod

```bash
# Check istiod pod is running
kubectl get pods -n istio-system -l app=istiod
# NAME                      READY   STATUS    RESTARTS   AGE
# istiod-xxxxxxxxx-xxxxx    1/1     Running   0          1m

# Check istiod service
kubectl get svc istiod -n istio-system

# Verify Istio version
kubectl get pods -n istio-system -l app=istiod \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

---

## Step 5-3: Deploy Istio Ingress Gateway with Samsung Cloud NLB

Deploy the Istio Ingress Gateway with Samsung Cloud-specific NLB annotations.

### Install Gateway

```bash
# Install Istio gateway from offline registry
helm install istio-ingressgateway \
  oci://${TARGET_REGISTRY}/helm/istio/gateway \
  --version ${ISTIO_VERSION} \
  -n istio-system \
  --set image="${TARGET_REGISTRY}/istio/proxyv2:${ISTIO_VERSION}" \
  --wait
```

### Apply NLB Service Configuration

Apply the Samsung Cloud NLB-specific service configuration (see `istio-ingressgateway-nlb.yaml`):

```bash
kubectl apply -f istio-ingressgateway-nlb.yaml
```

The service includes Samsung Cloud annotations:
- `scp-load-balancer-public-ip-enabled: "true"` — Enables public IP NAT
- `scp-load-balancer-public-ip-id` — Links to pre-allocated Public IP UUID
- `scp-load-balancer-source-ranges-firewall-rules: "true"` — Enables source range firewall

### Verify NLB Assignment

```bash
# Check service has External IP
kubectl get svc istio-ingressgateway -n istio-system
# NAME                   TYPE           CLUSTER-IP      EXTERNAL-IP
# istio-ingressgateway   LoadBalancer   172.20.x.x      123.41.32.188

# Wait for LoadBalancer to be provisioned (may take several minutes)
kubectl get svc istio-ingressgateway -n istio-system -w

# Verify both internal and external IPs
kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}'
# Expected: 192.168.10.x (internal VIP) 123.41.32.188 (public VIP)
```

> **Note:** Samsung Cloud NLB provisioning takes several minutes. Wait until `EXTERNAL-IP` shows the public IP.

---

## Step 5-4: Generate TLS Certificate

Generate a wildcard TLS certificate for the FQDN.

### Option A: Self-Signed Certificate (Dev/Test)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=${FQDN}" \
  -addext "subjectAltName=DNS:${FQDN},DNS:*.${FQDN}"
```

### Option B: CA-Signed Certificate (Production)

Generate a CSR and submit to your Certificate Authority:

```bash
# Generate private key
openssl genrsa -out tls.key 2048

# Generate CSR with SAN
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=${FQDN}" \
  -addext "subjectAltName=DNS:${FQDN},DNS:*.${FQDN}"

# Submit tls.csr to your CA
# Receive tls.crt (certificate) and ca.crt (CA chain)
echo "Submit CSR to CA and obtain signed certificate"
```

### Option C: Let's Encrypt (if internet accessible)

```bash
# Using certbot
certbot certonly --manual --preferred-challenges dns \
  -d "${FQDN}" -d "*.${FQDN}"

# Certificates will be in /etc/letsencrypt/live/${FQDN}/
cp /etc/letsencrypt/live/${FQDN}/fullchain.pem tls.crt
cp /etc/letsencrypt/live/${FQDN}/privkey.pem tls.key
cp /etc/letsencrypt/live/${FQDN}/chain.pem ca.crt
```

### Verify Certificate

```bash
# Check certificate details
openssl x509 -in tls.crt -text -noout | grep -A 2 "Subject Alternative Name"
# Expected: DNS:ske.myrobots.co.kr, DNS:*.ske.myrobots.co.kr

# Verify key matches certificate
openssl x509 -noout -modulus -in tls.crt | md5sum
openssl rsa -noout -modulus -in tls.key | md5sum
# Both MD5 sums must match
```

---

## Step 5-5: Create TLS Secret

Create the `istio-ingressgateway-certs` secret in `istio-system` namespace.

> **Critical:** The secret MUST include `ca.crt`. The `uipathctl` tool validates the certificate chain.

```bash
# For self-signed: use tls.crt as ca.crt
kubectl create secret generic istio-ingressgateway-certs \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  -n istio-system

# For self-signed certificates where ca.crt is the same as tls.crt:
# kubectl create secret generic istio-ingressgateway-certs \
#   --from-file=tls.crt=tls.crt \
#   --from-file=tls.key=tls.key \
#   --from-file=ca.crt=tls.crt \
#   -n istio-system
```

### Verify Secret

```bash
# Check secret exists with all required keys
kubectl get secret istio-ingressgateway-certs -n istio-system \
  -o jsonpath='{.data}' | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
# Expected: ['ca.crt', 'tls.crt', 'tls.key']

# Verify certificate in secret matches expected FQDN
kubectl get secret istio-ingressgateway-certs -n istio-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject Alternative"
```

---

## Step 5-6: Verify NLB Gets External IP

Final verification that the complete Istio + NLB stack is working.

```bash
# Check service status
kubectl get svc istio-ingressgateway -n istio-system -o wide

# Check all Istio pods are running
kubectl get pods -n istio-system
# Expected:
# istiod-xxxxx                    1/1     Running
# istio-ingressgateway-xxxxx      1/1     Running

# Test HTTPS connectivity (will show certificate error for self-signed)
curl -vk https://${PUBLIC_IP} 2>&1 | grep "SSL connection"
# Expected: SSL connection using TLS...

# Test with FQDN (after DNS is configured)
curl -vk https://${FQDN} 2>&1 | grep "subject:"
# Expected: subject: CN=ske.myrobots.co.kr

# Check NodePort assignments
kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{range .spec.ports[*]}{.name}{": "}{.port}{" → NodePort "}{.nodePort}{"\n"}{end}'
# Expected:
# status-port: 15021 → NodePort 3xxxx
# http2: 80 → NodePort 3xxxx
# https: 443 → NodePort 3xxxx
```

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| Istio CRDs | `kubectl get crds \| grep istio \| wc -l` | 10+ CRDs |
| istiod running | `kubectl get pods -n istio-system -l app=istiod` | 1/1 Running |
| Gateway running | `kubectl get pods -n istio-system -l app=istio-ingressgateway` | 1/1 Running |
| NLB External IP | `kubectl get svc istio-ingressgateway -n istio-system` | EXTERNAL-IP shows public IP |
| TLS secret | `kubectl get secret istio-ingressgateway-certs -n istio-system` | Exists |
| Secret keys | Check secret data keys | ca.crt, tls.crt, tls.key |
| HTTPS reachable | `curl -vk https://${PUBLIC_IP}` | SSL handshake succeeds |

---

## Troubleshooting

### NLB Stuck in Pending

```bash
# Check service events
kubectl describe svc istio-ingressgateway -n istio-system

# Common causes:
# - Invalid Public IP ID → verify UUID
# - Subnet not configured for LB → check Samsung Cloud VPC settings
# - Firewall blocking LB provisioning → check LB firewall rules
# - NLB takes 3-5 minutes to provision → wait and retry
```

### Certificate Issues

```bash
# Verify certificate chain
openssl verify -CAfile ca.crt tls.crt

# Check certificate expiry
openssl x509 -in tls.crt -noout -enddate

# Re-create secret if needed
kubectl delete secret istio-ingressgateway-certs -n istio-system
kubectl create secret generic istio-ingressgateway-certs \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  -n istio-system
```

### Gateway Not Receiving Traffic

```bash
# Check gateway pod logs
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=50

# Check istiod logs for configuration errors
kubectl logs -n istio-system -l app=istiod --tail=50

# Verify gateway listeners
kubectl exec -n istio-system $(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s localhost:15000/listeners | head -20
```

---

## Reference

- [UiPath: Installing and configuring the service mesh](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/installing-and-configuring-the-service-mesh)
- [Samsung Cloud SKE LoadBalancer](https://docs.e.samsungsdscloud.com/userguide/container/k8s_engine/usage_guide/k8s_typelb_use/)
- [UiPath Compatibility Matrix](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-openshift/compatibility-matrix)
