# Phase 3: Network, NLB & Firewall Configuration

This guide covers Samsung Cloud VPC networking, NLB (Network Load Balancer) setup, and firewall rules required for UiPath Automation Suite.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Samsung Cloud VPC                              │
│                                                                         │
│  ┌─────────────┐    ┌──────────────────┐    ┌───────────────────────┐  │
│  │  Internet   │    │  Public Subnet    │    │   Private Subnet      │  │
│  │  Gateway    │───▶│  (Load Balancer)  │───▶│   (Worker Nodes)      │  │
│  │             │    │                   │    │                       │  │
│  │  IGW F/W    │    │   NLB (L4)       │    │   SKE Worker Nodes    │  │
│  │  (Inbound)  │    │   LB F/W         │    │   Security Group      │  │
│  └─────────────┘    └──────────────────┘    └───────────────────────┘  │
│                                                                         │
│  Flow: Internet → IGW → IGW F/W → Public Subnet (NLB) → LB F/W →      │
│        Private Subnet (Workers + Security Group)                        │
└─────────────────────────────────────────────────────────────────────────┘
```

> **Reference:** See `load_balancer_overview.png` for the detailed Samsung Cloud VPC architecture diagram.

## Prerequisites

| Item | Requirement |
|------|-------------|
| SKE Cluster | Running with worker nodes (Phase 2) |
| VPC | Configured with public and private subnets |
| Public IP | Available for allocation |
| DNS | Access to DNS management |

## Configuration Variables

```bash
export FQDN="ske.myrobots.co.kr"
export PUBLIC_IP="123.41.32.188"
export PUBLIC_IP_ID="a5168593ce6c44d68e7255606eb07d14"
export NODEPORT_RANGE="30000-32767"
```

---

## Step 3-1: VPC Architecture Understanding

Samsung Cloud VPC uses a layered firewall approach:

| Layer | Component | Purpose |
|-------|-----------|---------|
| 1 | Internet Gateway Firewall | Controls traffic entering from internet |
| 2 | Load Balancer Firewall | Controls traffic between NLB and worker nodes |
| 3 | Security Group | Controls traffic at the worker node level |

### Traffic Flow

```
Client Request (HTTPS:443)
  │
  ▼
Internet Gateway
  │ IGW Firewall: Allow inbound to LB Service IP:80,443
  ▼
Public Subnet — NLB (Load Balancer)
  │ LB Firewall: Allow outbound to Worker:NodePort
  │              Allow inbound HealthCheck/SourceNAT to Worker:NodePort
  ▼
Private Subnet — Worker Nodes
  │ Security Group: Allow inbound from LB SourceNAT/HealthCheck to NodePort
  ▼
Istio Ingress Gateway Pod (NodePort Service)
  │
  ▼
UiPath Services (via VirtualService routing)
```

---

## Step 3-2: Create Public IP

1. Log in to Samsung Cloud Console
2. Navigate to **Networking > Public IP**
3. Click **Create Public IP**

| Setting | Value |
|---------|-------|
| Name | `uipath-as-public-ip` |
| Region | kr-west1 |
| Description | Public IP for UiPath Automation Suite NLB |

4. Note the allocated IP address and UUID

### Verify Public IP

```bash
# Record these values
echo "Public IP: ${PUBLIC_IP}"
echo "Public IP UUID: ${PUBLIC_IP_ID}"
```

---

## Step 3-3: Configure Internet Gateway Firewall

Navigate to **Networking > Internet Gateway > Firewall Rules**

### Inbound Rules

| Priority | Direction | Source | Destination | Port | Protocol | Action |
|----------|-----------|--------|-------------|------|----------|--------|
| 100 | Inbound | 0.0.0.0/0 (Any) | ${PUBLIC_IP}/32 | 80 | TCP | ALLOW |
| 101 | Inbound | 0.0.0.0/0 (Any) | ${PUBLIC_IP}/32 | 443 | TCP | ALLOW |

> **Note:** For production, restrict source IPs to known client ranges instead of 0.0.0.0/0.

### Verification

```bash
# From external network, verify port is reachable (after NLB is created)
nc -zv ${PUBLIC_IP} 443
curl -k https://${PUBLIC_IP} --connect-timeout 5
```

---

## Step 3-4: Configure Load Balancer Firewall

Navigate to **Networking > Load Balancer > Firewall Rules**

### Outbound Rules (NLB → Worker Nodes)

| Priority | Direction | Source | Destination | Port | Protocol | Action |
|----------|-----------|--------|-------------|------|----------|--------|
| 100 | Outbound | LB Service IP | Worker Nodes | 30000-32767 | TCP | ALLOW |
| 101 | Outbound | LB Service IP | Worker Nodes | 80 | TCP | ALLOW |
| 102 | Outbound | LB Service IP | Worker Nodes | 443 | TCP | ALLOW |

### Inbound Rules (Health Check + Source NAT → Worker Nodes)

| Priority | Direction | Source | Destination | Port | Protocol | Action |
|----------|-----------|--------|-------------|------|----------|--------|
| 100 | Inbound | Health Check IP | Worker Nodes | 30000-32767 | TCP | ALLOW |
| 101 | Inbound | Source NAT IP | Worker Nodes | 30000-32767 | TCP | ALLOW |
| 102 | Inbound | Any | Worker Nodes | 80 | TCP | ALLOW |
| 103 | Inbound | Any | Worker Nodes | 443 | TCP | ALLOW |

> **Note:** The Health Check IP and Source NAT IP are provided by Samsung Cloud when the NLB is created. Check the NLB details page for these values.

---

## Step 3-5: Configure Security Group

Navigate to **Networking > Security Group** (attached to worker node subnet)

### Inbound Rules

| Priority | Direction | Source | Destination | Port | Protocol | Action |
|----------|-----------|--------|-------------|------|----------|--------|
| 100 | Inbound | LB Source NAT IP | Worker Nodes | 30000-32767 | TCP | ALLOW |
| 101 | Inbound | Health Check IP | Worker Nodes | 30000-32767 | TCP | ALLOW |

### Additional Rules (Inter-node Communication)

| Priority | Direction | Source | Destination | Port | Protocol | Action |
|----------|-----------|--------|-------------|------|----------|--------|
| 200 | Inbound | Private Subnet CIDR | Worker Nodes | All | All | ALLOW |
| 201 | Outbound | Worker Nodes | Any | All | All | ALLOW |

---

## Step 3-6: Configure DNS Records

Create DNS records pointing to the Public IP:

### Required DNS Records

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `ske.myrobots.co.kr` | `123.41.32.188` | 300 |
| A | `*.ske.myrobots.co.kr` | `123.41.32.188` | 300 |

The wildcard record is required for:
- `alm.ske.myrobots.co.kr` — ArgoCD UI
- `monitoring.ske.myrobots.co.kr` — Monitoring (if enabled)
- `apps.ske.myrobots.co.kr` — UiPath Apps
- `insights.ske.myrobots.co.kr` — Insights (if enabled)

### Configure DNS

Use your DNS provider (Samsung Cloud DNS, external DNS, or internal DNS server):

```bash
# Example: Using Samsung Cloud DNS
# Navigate to Networking > DNS > Hosted Zone
# Add A records for FQDN and wildcard

echo "Configure DNS:"
echo "  A record: ${FQDN} → ${PUBLIC_IP}"
echo "  A record: *.${FQDN} → ${PUBLIC_IP}"
```

---

## Step 3-7: Verify DNS Resolution

```bash
# Verify base FQDN
nslookup ${FQDN}
# Expected: Address: 123.41.32.188

# Verify wildcard
nslookup alm.${FQDN}
# Expected: Address: 123.41.32.188

# Verify with dig (more detail)
dig ${FQDN} +short
dig alm.${FQDN} +short
dig monitoring.${FQDN} +short
```

---

## Firewall Rules Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    Firewall Configuration Summary                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Internet Gateway Firewall (IGW F/W):                        │
│     ┌─────────────────────────────────────────────────────┐     │
│     │ INBOUND: Source(Any) → LB IP:80,443  [ALLOW]        │     │
│     └─────────────────────────────────────────────────────┘     │
│                                                                  │
│  2. Load Balancer Firewall (LB F/W):                            │
│     ┌─────────────────────────────────────────────────────┐     │
│     │ OUTBOUND: LB IP → Workers:30000-32767  [ALLOW]      │     │
│     │ INBOUND:  HealthCheck → Workers:30000-32767 [ALLOW]  │     │
│     │ INBOUND:  SourceNAT → Workers:30000-32767  [ALLOW]   │     │
│     │ INBOUND/OUTBOUND: 80, 443  [ALLOW]                   │     │
│     └─────────────────────────────────────────────────────┘     │
│                                                                  │
│  3. Security Group (Worker Nodes):                               │
│     ┌─────────────────────────────────────────────────────┐     │
│     │ INBOUND: LB SourceNAT → NodePort 30000-32767 [ALLOW]│     │
│     │ INBOUND: HealthCheck → NodePort 30000-32767  [ALLOW] │     │
│     └─────────────────────────────────────────────────────┘     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Verification Checklist

| Check | Method | Expected Result |
|-------|--------|-----------------|
| Public IP allocated | Samsung Cloud Console | IP assigned |
| IGW Firewall rules | Console > IGW > Firewall | Inbound 80/443 allowed |
| LB Firewall rules | Console > LB > Firewall | In/Outbound NodePort allowed |
| Security Group rules | Console > Security Group | NodePort from LB allowed |
| DNS A record | `nslookup ${FQDN}` | Resolves to Public IP |
| DNS wildcard | `nslookup alm.${FQDN}` | Resolves to Public IP |

---

## Troubleshooting

### NLB Not Responding

```bash
# Check if NLB is provisioned (after Istio deployment)
kubectl get svc istio-ingressgateway -n istio-system

# Verify NodePort assignments
kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[*].nodePort}'

# Check NLB health check status in Samsung Cloud Console
```

### DNS Not Resolving

```bash
# Check DNS propagation
dig ${FQDN} @8.8.8.8

# If using internal DNS, check from within the network
dig ${FQDN} @<internal-dns-server>

# Verify no conflicting DNS records
dig ${FQDN} ANY
```

### Firewall Blocking Traffic

```bash
# Test connectivity from internet to NLB
curl -vk https://${PUBLIC_IP} 2>&1 | grep -i "connect"

# Check if traffic reaches worker nodes (SSH to worker)
sudo tcpdump -i any port 32437 -n  # 32437 = HTTPS NodePort (example)

# Verify Samsung Cloud firewall logs in Console
```

---

## Reference

- [Samsung Cloud SKE LoadBalancer](https://docs.e.samsungsdscloud.com/userguide/container/k8s_engine/usage_guide/k8s_typelb_use/)
- Samsung Cloud VPC Firewall documentation
- `load_balancer_overview.png` (included in this project)
