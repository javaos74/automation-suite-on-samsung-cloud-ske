# 1단계: 오프라인 레지스트리 및 에어갭 환경 준비

삼성 클라우드 SKE에 에어갭 환경으로 UiPath Automation Suite을 배포하기 위한 오프라인 컨테이너 레지스트리 구성 및 이미지/Helm 차트 준비 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| 점프 서버 | 인터넷 접근이 가능한 Linux VM (RHEL 8/9 또는 Ubuntu 20.04+) |
| 컨테이너 런타임 | Docker 20.10+ 또는 Podman 4.x |
| Helm | v3.8+ |
| 디스크 공간 | 150 GB+ 여유 공간 (`/var/lib/docker` 또는 `/var/lib/containers` 하위) |
| 삼성 클라우드 레지스트리 | 삼성 클라우드 콘솔에서 생성한 OCI 호환 컨테이너 레지스트리 |
| 네트워크 | 점프 서버가 인터넷과 삼성 클라우드 레지스트리 모두에 접근 가능해야 함 |

## 환경 변수 설정

```bash
# === 삼성 클라우드 레지스트리 ===
export TARGET_REGISTRY="<삼성-클라우드-레지스트리-url>"
export REGISTRY_USERNAME="<레지스트리-사용자명>"
export REGISTRY_PASSWORD="<레지스트리-비밀번호>"

# === UiPath 버전 ===
export UIPATH_VERSION="2.2510.2"

# === 작업 디렉토리 ===
export WORK_DIR="/opt/uipath-offline"
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
```

---

## 1-1단계: 점프 서버 준비

점프 서버에 필요한 도구를 설치합니다:

```bash
# Docker 설치 (Podman을 사용하지 않는 경우)
sudo yum install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker

# Helm 설치
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# 디스크 공간 확인
df -h /var/lib/docker
```

---

## 1-2단계: 삼성 클라우드 컨테이너 레지스트리 생성

1. 삼성 클라우드 콘솔에 로그인
2. **컨테이너 > 컨테이너 레지스트리** 메뉴로 이동
3. 새 레지스트리 생성 (URL 기록)
4. 접근 자격 증명 생성 (사용자명/비밀번호 또는 토큰)

### 레지스트리 접근 확인

```bash
# 삼성 클라우드 레지스트리 로그인
docker login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}

# Podman 사용 시
podman login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}
```

---

## 1-3단계: 매니페스트 파일 및 버전 정보 다운로드

UiPath 문서 포털 또는 UiPath 담당자로부터 Automation Suite 매니페스트 파일을 다운로드합니다:

```bash
# 매니페스트 파일 다운로드
# - as-images.txt: 모든 컨테이너 이미지 목록
# - as-helm-charts.txt: 모든 Helm 차트 목록
# - versions.json: 버전 매핑 파일

ls -la ${WORK_DIR}/
# 예상 파일:
#   as-images.txt
#   as-helm-charts.txt
#   versions.json
```

### 매니페스트 내용 확인

```bash
# 이미지 수 확인
wc -l as-images.txt

# Helm 차트 수 확인
wc -l as-helm-charts.txt

# versions.json 미리보기
cat versions.json | python3 -m json.tool | head -30
```

---

## 1-4단계: 옵션 A — UiPath 레지스트리에서 미러링

점프 서버가 `registry.uipath.com`에 인터넷 접근이 가능한 경우 이 옵션을 사용합니다.

```bash
# UiPath에서 미러 스크립트 다운로드
# (Automation Suite 설치 패키지에 포함)

# mirror-registry.sh 실행
chmod +x mirror-registry.sh

./mirror-registry.sh \
  --target-registry-url ${TARGET_REGISTRY} \
  --target-registry-username ${REGISTRY_USERNAME} \
  --target-registry-password ${REGISTRY_PASSWORD} \
  --images-manifest ${WORK_DIR}/as-images.txt \
  --helm-charts-manifest ${WORK_DIR}/as-helm-charts.txt
```

### 미러링 확인

```bash
# 대상 레지스트리에 샘플 이미지가 존재하는지 확인
docker pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}

# 샘플 Helm 차트 확인
helm pull oci://${TARGET_REGISTRY}/helm/uipath/orchestrator --version ${UIPATH_VERSION}
```

---

## 1-5단계: 옵션 B — 오프라인 번들에서 하이드레이션

점프 서버가 인터넷에 직접 접근할 수 없는 완전한 에어갭 환경에서 이 옵션을 사용합니다.

### 오프라인 번들 다운로드 (인터넷 접근 가능한 머신에서)

```bash
# UiPath 고객 포털에서 as-cmk.tar.gz 다운로드
# USB, SFTP 또는 기타 보안 방법으로 점프 서버에 전송
ls -lh ${WORK_DIR}/as-cmk.tar.gz
```

### 레지스트리 하이드레이션

```bash
# Podman 설치 (하이드레이션 스크립트에 필요)
sudo yum install -y podman

# 하이드레이션 스크립트 실행
chmod +x hydrate-registry.sh

./hydrate-registry.sh \
  --target-registry-url ${TARGET_REGISTRY} \
  --target-registry-username ${REGISTRY_USERNAME} \
  --target-registry-password ${REGISTRY_PASSWORD} \
  --offline-bundle-path ${WORK_DIR}/as-cmk.tar.gz \
  --extract-path /tmp
```

### 하이드레이션 확인

```bash
# 샘플 이미지 확인
podman pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}

# 리포지토리 목록 확인 (레지스트리가 카탈로그 API를 지원하는 경우)
curl -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} \
  https://${TARGET_REGISTRY}/v2/_catalog | python3 -m json.tool | head -20
```

---

## 1-6단계: 추가 Helm 차트 미러링

UiPath 번들에는 Istio, ArgoCD, NFS 프로비저너 차트가 포함되어 있지 않습니다. 이를 별도로 미러링합니다.

### Istio 차트 미러링 (v1.30.x)

```bash
# Istio Helm 차트 Pull
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 차트 다운로드
helm pull istio/base --version 1.30.2 --destination ${WORK_DIR}/charts/
helm pull istio/istiod --version 1.30.2 --destination ${WORK_DIR}/charts/
helm pull istio/gateway --version 1.30.2 --destination ${WORK_DIR}/charts/

# 삼성 클라우드 레지스트리에 Push (OCI)
helm push ${WORK_DIR}/charts/base-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
helm push ${WORK_DIR}/charts/istiod-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
helm push ${WORK_DIR}/charts/gateway-1.30.2.tgz oci://${TARGET_REGISTRY}/helm/istio
```

### ArgoCD 차트 미러링 (v10.x)

```bash
# ArgoCD Helm 차트 Pull
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm pull argo/argo-cd --version 10.1.1 --destination ${WORK_DIR}/charts/

# 삼성 클라우드 레지스트리에 Push
helm push ${WORK_DIR}/charts/argo-cd-10.1.1.tgz oci://${TARGET_REGISTRY}/helm/argo
```

### NFS Subdir External Provisioner 미러링

```bash
# NFS 프로비저너 차트 Pull
helm repo add nfs-subdir https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

helm pull nfs-subdir/nfs-subdir-external-provisioner --destination ${WORK_DIR}/charts/

# 삼성 클라우드 레지스트리에 Push
helm push ${WORK_DIR}/charts/nfs-subdir-external-provisioner-*.tgz oci://${TARGET_REGISTRY}/helm/nfs
```

### 추가 컴포넌트 컨테이너 이미지 미러링

```bash
# Istio 이미지
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

# ArgoCD 이미지 (argo-cd 차트 values.yaml에서 정확한 이미지 확인)
ARGOCD_IMAGES=(
  "quay.io/argoproj/argocd:v3.4.4"
  "ghcr.io/dexidp/dex:v2.41.1"
  "public.ecr.aws/docker/library/redis:7.4.2-alpine"
)

for img in "${ARGOCD_IMAGES[@]}"; do
  docker pull ${img}
  # 대상 레지스트리 접두사로 태그 재지정
  IMG_NAME=$(echo ${img} | sed 's|.*/||')
  docker tag ${img} ${TARGET_REGISTRY}/mirror/${IMG_NAME}
  docker push ${TARGET_REGISTRY}/mirror/${IMG_NAME}
done
```

---

## 1-7단계: uipathctl 바이너리 다운로드

```bash
# UiPath에서 uipathctl 다운로드
# (Automation Suite 설치 패키지 또는 UiPath 다운로드 포털에서 제공)

# 실행 권한 부여
chmod +x uipathctl

# 버전 확인
./uipathctl version

# 표준 경로로 이동
sudo mv uipathctl /usr/local/bin/
uipathctl version
```

---

## 1-8단계: 모든 노드에 레지스트리 인증서 신뢰 구성

삼성 클라우드 레지스트리가 사설 CA 인증서를 사용하는 경우 모든 클러스터 노드에서 해당 인증서를 신뢰해야 합니다.

### 옵션 A: 노드 풀 사전 구성 (권장)

삼성 클라우드 콘솔에서 노드 풀 생성 시 CA 신뢰를 구성합니다 (지원되는 경우).

### 옵션 B: 각 노드에 수동 구성

```bash
# 각 노드에 레지스트리 CA 인증서 복사
# (SSH 또는 Ansible 같은 자동화 도구 사용)

# 각 워커 노드에서:
sudo cp registry-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# 새 인증서 적용을 위해 containerd 재시작
sudo systemctl restart containerd
```

### 옵션 C: containerd 레지스트리 미러 구성

```bash
# 각 노드에서 /etc/containerd/config.toml 편집
# 레지스트리 미러 구성 추가:

# [plugins."io.containerd.grpc.v1.cri".registry.mirrors."<TARGET_REGISTRY>"]
#   endpoint = ["https://<TARGET_REGISTRY>"]
# [plugins."io.containerd.grpc.v1.cri".registry.configs."<TARGET_REGISTRY>".tls]
#   ca_file = "/etc/pki/ca-trust/source/anchors/registry-ca.crt"

sudo systemctl restart containerd
```

### 노드에서 레지스트리 접근 확인

```bash
# 워커 노드에서 이미지 Pull 확인
sudo crictl pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}
```

---

## 검증 체크리스트

| 확인 항목 | 명령어 | 예상 결과 |
|-----------|--------|-----------|
| 레지스트리 로그인 | `docker login ${TARGET_REGISTRY}` | Login Succeeded |
| UiPath 이미지 존재 | `docker pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}` | Pull 성공 |
| Helm 차트 존재 | `helm pull oci://${TARGET_REGISTRY}/helm/uipath/orchestrator` | 차트 다운로드 성공 |
| Istio 차트 존재 | `helm pull oci://${TARGET_REGISTRY}/helm/istio/base --version 1.30.2` | 차트 다운로드 성공 |
| ArgoCD 차트 존재 | `helm pull oci://${TARGET_REGISTRY}/helm/argo/argo-cd --version 10.1.1` | 차트 다운로드 성공 |
| NFS 차트 존재 | `helm pull oci://${TARGET_REGISTRY}/helm/nfs/nfs-subdir-external-provisioner` | 차트 다운로드 성공 |
| uipathctl 동작 | `uipathctl version` | 버전 표시 |
| 노드 레지스트리 접근 | `crictl pull ${TARGET_REGISTRY}/uipath/orchestrator:${UIPATH_VERSION}` | 노드에서 Pull 성공 |

---

## 참고 자료

- [UiPath OCI 레지스트리 구성](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/configuring-the-oci-compliant-registry)
- 삼성 클라우드 컨테이너 레지스트리 문서
