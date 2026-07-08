# Phase 1: Offline Registry & Airgap Preparation

This guide covers setting up the offline container registry and preparing all images and Helm charts required for an airgapped UiPath Automation Suite deployment on Samsung Cloud SKE.

## Prerequisites

| Item | Requirement |
|------|-------------|
| Jump Server | Linux VM with internet access (RHEL 8/9 or Ubuntu 20.04+) |
| Container Runtime | Docker 20.10+ or Podman 4.x |
| Helm | v3.8+ |
| Disk Space | 150 GB+ free (under `/var/lib/docker` or `/var/lib/containers`) |
| Samsung Cloud Registry | OCI-compliant Container Registry created in Samsung Cloud console |
| Network | Jump server must reach both internet and Samsung Cloud Registry |

## Configuration Variables

```bash
# === Samsung Cloud Registry ===
export TARGET_REGISTRY="<samsung-cloud-registry-url>"
export REGISTRY_USERNAME="<registry-username>"
export REGISTRY_PASSWORD="<registry-password>"

# === UiPath Version ===
export UIPATH_VERSION="2.2510.2"

# === Working Directory ===
export WORK_DIR="/opt/uipath-offline"
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
```

---

## Step 1-1: Prepare Jump Server

Install required tools on the jump server:

```bash
# Install Docker (if not using Podman)
sudo yum install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# Verify disk space
df -h /var/lib/docker
```

---

## Step 1-2: Create Samsung Cloud Container Registry

1. Log in to Samsung Cloud Console
2. Navigate to **Container > Container Registry**
3. Create a new registry (note the URL)
4. Create access credentials (username/password or token)

### Verify Registry Access

```bash
# Login to Samsung Cloud Registry
docker login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}

# Or with Podman
podman login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}
```

---

## Step 1-3: Download Manifest Files and Versions

Download the UiPath Automation Suite manifest files from the UiPath documentation portal or your UiPath representative:

```bash
# Download manifest files
# - as-images.txt: List of all container images
# - as-helm-charts.txt: List of all Helm charts
# - versions.json: Version mapping file

ls -la ${WORK_DIR}/
# Expected files:
#   as-images.txt
#   as-helm-charts.txt
#   versions.json
```

### Verify Manifest Contents

```bash
# Check image count
wc -l as-images.txt

# Check helm chart count
wc -l as-helm-charts.txt

# Preview versions.json
cat versions.json | python3 -m json.tool | head -30
```

---

## Step 1-4: Option A — Mirror from UiPath Registry

Use this option if the jump server has internet access to `registry.uipath.com`.

```bash
# Download the mirror script from UiPath
# (provided with Automation Suite installation package)

# Run mirror-registry.sh
chmod +x mirror-registry.sh

./mirror-registry.sh \
  --target-registry-url ${TARGET_REGISTRY} \
  --target-registry-username ${REGISTRY_USERNAME} \
  --target-registry-password ${REGISTRY_PASSWORD} \
  --images-manifest ${WORK_DIR}/as-images.txt \
  --helm-charts-manifest ${WORK_DIR}/as-helm-charts.txt
```

### Verify Mirror

```bash
# Check a sample image exists in target registry
docker pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}

# Check a sample Helm chart
helm pull oci://${TARGET_REGISTRY}/helm/uipath/orchestrator --version ${UIPATH_VERSION}
```

---

## Step 1-5: Option B — Hydrate from Offline Bundle

Use this option for fully airgapped environments where the jump server cannot reach the internet directly.

### Download Offline Bundle (on internet-connected machine)

```bash
# Download as-cmk.tar.gz from UiPath Customer Portal
# Transfer to the jump server via USB, SFTP, or other secure method
ls -lh ${WORK_DIR}/as-cmk.tar.gz
```

### Hydrate Registry

```bash
# Install Podman (required for hydrate script)
sudo yum install -y podman

# Run hydrate script
chmod +x hydrate-registry.sh

./hydrate-registry.sh \
  --target-registry-url ${TARGET_REGISTRY} \
  --target-registry-username ${REGISTRY_USERNAME} \
  --target-registry-password ${REGISTRY_PASSWORD} \
  --offline-bundle-path ${WORK_DIR}/as-cmk.tar.gz \
  --extract-path /tmp
```

### Verify Hydration

```bash
# Check sample image
podman pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}

# List repositories (if registry supports catalog API)
curl -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} \
  https://${TARGET_REGISTRY}/v2/_catalog | python3 -m json.tool | head -20
```

---

## Step 1-6: Mirror Additional Helm Charts

UiPath does not include Istio, ArgoCD, or NFS provisioner charts in the bundle. Mirror these separately.

### Mirror Istio Charts (v1.30.x)

```bash
# Pull Istio Helm charts
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Download charts
helm pull istio/base --version 1.30.2 --destination ${WORK_DIR}/charts/
helm pull istio/istiod --version 1.30.2 --destination ${WORK_DIR}/charts/
helm pull istio/gateway --version 1.30.2 --destination ${WORK_DIR}/charts/

# Push to Samsung Cloud Registry (OCI)
helm push ${WORK_DIR}/charts/base-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
helm push ${WORK_DIR}/charts/istiod-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
helm push ${WORK_DIR}/charts/gateway-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
```

### Mirror ArgoCD Chart (v10.x)

```bash
# Pull ArgoCD Helm chart
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm pull argo/argo-cd --version 10.1.1 --destination ${WORK_DIR}/charts/

# Push to Samsung Cloud Registry
helm push ${WORK_DIR}/charts/argo-cd-10.1.1.tgz oci://${TARGET_REGISTRY}/helm/argo
```

### Mirror NFS Subdir External Provisioner

```bash
# Pull NFS provisioner chart
helm repo add nfs-subdir https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

helm pull nfs-subdir/nfs-subdir-external-provisioner --destination ${WORK_DIR}/charts/

# Push to Samsung Cloud Registry
helm push ${WORK_DIR}/charts/nfs-subdir-external-provisioner-*.tgz oci://${TARGET_REGISTRY}/helm/nfs
```

### Mirror Container Images for Additional Components

```bash
# Istio images
ISTIO_IMAGES=(
  "docker.io/istio/proxyv2:1.30.2"
  "docker.io/istio/pilot:1.30.2"
)

for img in "${ISTIO_IMAGES[@]}"; do
  docker pull ${img}
  TARGET_TAG="${TARGET_REGISTRY}/$(echo ${img} | cut -d'/' -f2-)"
  docker tag ${img} ${TARGET_TAG}
  docker push ${TARGET_TAG}
done

# ArgoCD images (check argo-cd chart values.yaml for exact images)
ARGOCD_IMAGES=(
  "quay.io/argoproj/argocd:v3.4.4"
  "ghcr.io/dexidp/dex:v2.41.1"
  "public.ecr.aws/docker/library/redis:7.4.2-alpine"
)

for img in "${ARGOCD_IMAGES[@]}"; do
  docker pull ${img}
  # Re-tag with target registry prefix
  IMG_NAME=$(echo ${img} | sed 's|.*/||')
  docker tag ${img} ${TARGET_REGISTRY}/mirror/${IMG_NAME}
  docker push ${TARGET_REGISTRY}/mirror/${IMG_NAME}
done
```

---

## Step 1-7: Download uipathctl Binary

```bash
# Download uipathctl from UiPath
# (provided with Automation Suite installation package or UiPath downloads portal)

# Make executable
chmod +x uipathctl

# Verify version
./uipathctl version

# Move to a standard location
sudo mv uipathctl /usr/local/bin/
uipathctl version
```

---

## Step 1-8: Configure Registry Certificate Trust on All Nodes

If the Samsung Cloud Registry uses a private CA certificate, all cluster nodes must trust it.

### Option A: Pre-configure via Node Pool (Recommended)

Configure the CA trust during node pool creation in Samsung Cloud console, if supported.

### Option B: Manual Configuration on Each Node

```bash
# Copy the registry CA certificate to each node
# (Use SSH or automation tool like Ansible)

# On each worker node:
sudo cp registry-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Restart containerd to pick up new certificates
sudo systemctl restart containerd
```

### Option C: Configure containerd Registry Mirror

```bash
# On each node, edit /etc/containerd/config.toml
# Add registry mirror configuration:

# [plugins."io.containerd.grpc.v1.cri".registry.mirrors."<TARGET_REGISTRY>"]
#   endpoint = ["https://<TARGET_REGISTRY>"]
# [plugins."io.containerd.grpc.v1.cri".registry.configs."<TARGET_REGISTRY>".tls]
#   ca_file = "/etc/pki/ca-trust/source/anchors/registry-ca.crt"

sudo systemctl restart containerd
```

### Verify Node Access to Registry

```bash
# On a worker node, verify pulling an image
sudo crictl pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}
```

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| Registry login | `docker login ${TARGET_REGISTRY}` | Login Succeeded |
| UiPath images present | `docker pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}` | Pull succeeds |
| Helm charts present | `helm pull oci://${TARGET_REGISTRY}/helm/uipath/orchestrator` | Chart downloaded |
| Istio charts present | `helm pull oci://${TARGET_REGISTRY}/helm/istio/base --version 1.30.2` | Chart downloaded |
| ArgoCD chart present | `helm pull oci://${TARGET_REGISTRY}/helm/argo/argo-cd --version 10.1.1` | Chart downloaded |
| NFS chart present | `helm pull oci://${TARGET_REGISTRY}/helm/nfs/nfs-subdir-external-provisioner` | Chart downloaded |
| uipathctl works | `uipathctl version` | Version displayed |
| Node registry access | `crictl pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}` | Pull succeeds on node |

---

## Reference

- [UiPath OCI Registry Configuration](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/configuring-the-oci-compliant-registry)
- Samsung Cloud Container Registry documentation
