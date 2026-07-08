# Phase 2: SKE Cluster & Node Pool Configuration

This guide covers creating and configuring the Samsung Kubernetes Engine (SKE) cluster and node pools for UiPath Automation Suite deployment.

## Prerequisites

| Item | Requirement |
|------|-------------|
| Samsung Cloud Account | With Cluster Admin privileges |
| VPC | Pre-configured VPC with subnets |
| Registry | Offline registry prepared (Phase 1) |
| kubectl | Configured with SKE cluster access |

## Cluster Specifications

| Item | Value |
|------|-------|
| K8s Version | v1.34.x (latest stable on SKE) |
| Region | kr-west1 |
| Zone | kr-west1-b |
| Container Runtime | containerd |
| CNI | Calico (SKE default) |
| OS | Red Hat Enterprise Linux 9.4 |

---

## Step 2-1: Create Dedicated SKE Cluster

1. Log in to Samsung Cloud Console
2. Navigate to **Container > Kubernetes Engine**
3. Click **Create Cluster**

### Cluster Settings

| Setting | Value |
|---------|-------|
| Cluster Name | `uipath-as-cluster` |
| K8s Version | Latest stable (v1.34.x) |
| Region/Zone | kr-west1 / kr-west1-b |
| VPC | Select your pre-configured VPC |
| Subnet | Select private subnet for worker nodes |
| Service CIDR | `172.20.0.0/16` (default) |
| Pod CIDR | `10.244.0.0/16` (default) |
| Cluster Access | Private + Public (for initial setup) |

### Verify Cluster

```bash
# Download kubeconfig from Samsung Cloud console
# or use Samsung Cloud CLI

# Verify cluster access
kubectl get nodes
kubectl version

# Verify Kubernetes version
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'
```

---

## Step 2-2: Create General Worker Node Pool

This pool hosts all UiPath platform services.

### Samsung Cloud Console

1. Navigate to your cluster > **Node Pools**
2. Click **Add Node Pool**

| Setting | Value |
|---------|-------|
| Pool Name | `ske-worker-general` |
| Instance Type | 32 vCPU / 96 GB RAM |
| Node Count | 5 (minimum) |
| OS | RHEL 9.4 |
| Disk Size | 200 GB SSD |
| Auto-scaling | Optional (min 5, max 10) |

### Verify General Worker Nodes

```bash
# Check nodes are Ready
kubectl get nodes -l pool=ske-worker-general

# Verify node resources
kubectl describe nodes | grep -A 5 "Allocatable"
```

---

## Step 2-3: Create ASRobot Dedicated Node Pool

This pool is exclusively for Automation Suite Robots (ASRobots) with package caching.

### Samsung Cloud Console

| Setting | Value |
|---------|-------|
| Pool Name | `ske-worker-asrobot` |
| Instance Type | 32 vCPU / 64 GB RAM |
| Node Count | 1 (minimum) |
| OS | RHEL 9.4 |
| Disk Size | 200 GB SSD |

### Apply Labels and Taints

```bash
# Get ASRobot node names
ASROBOT_NODES=$(kubectl get nodes -l pool=ske-worker-asrobot -o jsonpath='{.items[*].metadata.name}')

# Apply required labels
for node in ${ASROBOT_NODES}; do
  kubectl label node ${node} serverless.daemon=true
  kubectl label node ${node} serverless.robot=true
  echo "Labeled node: ${node}"
done

# Apply taint to prevent non-ASRobot workloads
for node in ${ASROBOT_NODES}; do
  kubectl taint node ${node} serverless.robot=present:NoSchedule
  echo "Tainted node: ${node}"
done
```

### Verify ASRobot Node Configuration

```bash
# Check labels
kubectl get nodes -l serverless.daemon=true -o wide

# Check taints
kubectl describe nodes -l serverless.daemon=true | grep -A 3 "Taints"

# Expected output:
# Taints: serverless.robot=present:NoSchedule
```

---

## Step 2-4: Create GPU Dedicated Node Pool

This pool hosts AI Center GPU workloads with NVIDIA A100 GPUs.

### Samsung Cloud Console

| Setting | Value |
|---------|-------|
| Pool Name | `ske-worker-gpu` |
| Instance Type | 32 vCPU / 128 GB RAM / A100-80G |
| Node Count | 1 |
| OS | RHEL 9.4 |
| Disk Size | 500 GB SSD |
| GPU Type | NVIDIA A100 80GB |

### Apply GPU Labels

```bash
# Get GPU node names
GPU_NODES=$(kubectl get nodes -l pool=ske-worker-gpu -o jsonpath='{.items[*].metadata.name}')

# Apply GPU label
for node in ${GPU_NODES}; do
  kubectl label node ${node} nvidia.com/gpu.present=true
  echo "Labeled GPU node: ${node}"
done
```

### Install NVIDIA Device Plugin

```bash
# Apply NVIDIA device plugin DaemonSet
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: nvidia-device-plugin-ctr
        image: nvcr.io/nvidia/k8s-device-plugin:v0.17.0
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
EOF
```

### Install DCGM Exporter (GPU Monitoring)

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: dcgm-exporter
        image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04
        ports:
        - containerPort: 9400
          name: metrics
        securityContext:
          runAsNonRoot: false
          runAsUser: 0
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
EOF
```

---

## Step 2-5: Configure GPU MIG (Multi-Instance GPU)

NVIDIA MIG allows partitioning a single A100 GPU into multiple isolated GPU instances for better resource utilization.

### Apply MIG Configuration

Apply the MIG ConfigMap (see `gpu-mig-configmap.yaml`):

```bash
kubectl apply -f gpu-mig-configmap.yaml
```

### Deploy NVIDIA MIG Manager

Apply the MIG Manager DaemonSet (see `nvidia-mig-manager.yaml`):

```bash
kubectl apply -f nvidia-mig-manager.yaml
```

### Verify MIG Configuration

```bash
# Check MIG manager is running
kubectl get pods -n kube-system -l app=nvidia-mig-manager

# SSH to GPU node and verify MIG instances
# nvidia-smi mig -lgi
# Expected output shows MIG instances (e.g., 7 x 1g.10gb or 3 x 2g.20gb + 1 x 1g.10gb)

# Verify GPU resources visible to Kubernetes
kubectl describe node -l nvidia.com/gpu.present=true | grep -A 10 "Allocatable"
# Should show nvidia.com/gpu or nvidia.com/mig-* resources
```

---

## Step 2-6: Verify All Nodes Are Ready

```bash
# Check all nodes are Ready
kubectl get nodes -o wide

# Expected output:
# NAME                    STATUS   ROLES    AGE   VERSION         OS-IMAGE                          CONTAINER-RUNTIME
# ske-worker-general-1    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-2    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-3    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-4    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-5    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-asrobot-1    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-gpu-1        Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30

# Verify labels
echo "=== General Workers ==="
kubectl get nodes -l pool=ske-worker-general --show-labels

echo "=== ASRobot Workers ==="
kubectl get nodes -l serverless.daemon=true --show-labels

echo "=== GPU Workers ==="
kubectl get nodes -l nvidia.com/gpu.present=true --show-labels

# Verify taints on ASRobot nodes
echo "=== ASRobot Taints ==="
kubectl get nodes -l serverless.daemon=true -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.taints}{"\n"}{end}'
```

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| Cluster accessible | `kubectl get nodes` | All nodes listed |
| General workers ready | `kubectl get nodes -l pool=ske-worker-general` | 5+ nodes Ready |
| ASRobot workers ready | `kubectl get nodes -l serverless.daemon=true` | 1+ nodes Ready |
| ASRobot taint applied | `kubectl describe node -l serverless.daemon=true \| grep Taint` | `serverless.robot=present:NoSchedule` |
| GPU workers ready | `kubectl get nodes -l nvidia.com/gpu.present=true` | 1 node Ready |
| GPU plugin running | `kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds` | Running |
| MIG configured | `kubectl get pods -n kube-system -l app=nvidia-mig-manager` | Running |
| K8s version correct | `kubectl version` | v1.34.x |

---

## Troubleshooting

### Node Not Becoming Ready

```bash
# Check node conditions
kubectl describe node <NODE_NAME> | grep -A 10 "Conditions"

# Check kubelet logs (SSH to node)
journalctl -u kubelet -f --no-pager | tail -50
```

### GPU Not Detected

```bash
# SSH to GPU node
nvidia-smi

# Check NVIDIA driver version
cat /proc/driver/nvidia/version

# Restart device plugin
kubectl delete pods -n kube-system -l name=nvidia-device-plugin-ds
```

### ASRobot Pod Pending (After Deployment)

If ASRobot pods show `FailedScheduling`, verify:

```bash
# Check node affinity matches
kubectl get nodes --show-labels | grep serverless

# Verify CSI is running on tainted nodes (see Phase 4)
kubectl get pods -n kube-system -l app=csi-bs-node -o wide
```
