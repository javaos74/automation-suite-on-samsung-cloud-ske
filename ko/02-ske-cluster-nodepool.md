# 2단계: SKE 클러스터 및 노드 풀 구성

UiPath Automation Suite 배포를 위한 삼성 쿠버네티스 엔진(SKE) 클러스터 생성 및 노드 풀 구성 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| 삼성 클라우드 계정 | Cluster Admin 권한 보유 |
| VPC | 서브넷이 구성된 VPC |
| 레지스트리 | 오프라인 레지스트리 준비 완료 (1단계) |
| kubectl | SKE 클러스터 접근 구성 완료 |

## 클러스터 사양

| 항목 | 값 |
|------|-----|
| K8s 버전 | v1.34.x (SKE 최신 안정 버전) |
| 리전 | kr-west1 |
| 가용 영역 | kr-west1-b |
| 컨테이너 런타임 | containerd |
| CNI | Calico (SKE 기본값) |
| OS | Red Hat Enterprise Linux 9.4 |

---

## 2-1단계: 전용 SKE 클러스터 생성

1. 삼성 클라우드 콘솔에 로그인
2. **컨테이너 > 쿠버네티스 엔진** 메뉴로 이동
3. **클러스터 생성** 클릭

### 클러스터 설정

| 설정 | 값 |
|------|-----|
| 클러스터 이름 | `uipath-as-cluster` |
| K8s 버전 | 최신 안정 버전 (v1.34.x) |
| 리전/가용 영역 | kr-west1 / kr-west1-b |
| VPC | 사전 구성된 VPC 선택 |
| 서브넷 | 워커 노드용 프라이빗 서브넷 선택 |
| Service CIDR | `172.20.0.0/16` (기본값) |
| Pod CIDR | `10.244.0.0/16` (기본값) |
| 클러스터 접근 | Private + Public (초기 설정용) |

### 클러스터 확인

```bash
# 삼성 클라우드 콘솔에서 kubeconfig 다운로드
# 또는 삼성 클라우드 CLI 사용

# 클러스터 접근 확인
kubectl get nodes
kubectl version

# 쿠버네티스 버전 확인
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'
```

---

## 2-2단계: 일반 워커 노드 풀 생성

이 풀은 모든 UiPath 플랫폼 서비스를 호스팅합니다.

### 삼성 클라우드 콘솔

1. 클러스터 > **노드 풀** 메뉴로 이동
2. **노드 풀 추가** 클릭

| 설정 | 값 |
|------|-----|
| 풀 이름 | `ske-worker-general` |
| 인스턴스 타입 | 32 vCPU / 96 GB RAM |
| 노드 수 | 5 (최소) |
| OS | RHEL 9.4 |
| 디스크 크기 | 200 GB SSD |
| 오토 스케일링 | 선택 사항 (최소 5, 최대 10) |

### 일반 워커 노드 확인

```bash
# 노드 Ready 상태 확인
kubectl get nodes -l pool=ske-worker-general

# 노드 리소스 확인
kubectl describe nodes | grep -A 5 "Allocatable"
```

---

## 2-3단계: ASRobot 전용 노드 풀 생성

이 풀은 패키지 캐싱을 포함한 Automation Suite Robot(ASRobot) 전용입니다.

### 삼성 클라우드 콘솔

| 설정 | 값 |
|------|-----|
| 풀 이름 | `ske-worker-asrobot` |
| 인스턴스 타입 | 32 vCPU / 64 GB RAM |
| 노드 수 | 1 (최소) |
| OS | RHEL 9.4 |
| 디스크 크기 | 200 GB SSD |

### 레이블 및 테인트 적용

```bash
# ASRobot 노드 이름 조회
ASROBOT_NODES=$(kubectl get nodes -l pool=ske-worker-asrobot -o jsonpath='{.items[*].metadata.name}')

# 필수 레이블 적용
for node in ${ASROBOT_NODES}; do
  kubectl label node ${node} serverless.daemon=true
  kubectl label node ${node} serverless.robot=true
  echo "노드 레이블 적용: ${node}"
done

# 비-ASRobot 워크로드 방지를 위한 테인트 적용
for node in ${ASROBOT_NODES}; do
  kubectl taint node ${node} serverless.robot=present:NoSchedule
  echo "노드 테인트 적용: ${node}"
done
```

### ASRobot 노드 구성 확인

```bash
# 레이블 확인
kubectl get nodes -l serverless.daemon=true -o wide

# 테인트 확인
kubectl describe nodes -l serverless.daemon=true | grep -A 3 "Taints"

# 예상 출력:
# Taints: serverless.robot=present:NoSchedule
```

---

## 2-4단계: GPU 전용 노드 풀 생성

이 풀은 NVIDIA A100 GPU가 장착된 AI Center GPU 워크로드를 호스팅합니다.

### 삼성 클라우드 콘솔

| 설정 | 값 |
|------|-----|
| 풀 이름 | `ske-worker-gpu` |
| 인스턴스 타입 | 32 vCPU / 128 GB RAM / A100-80G |
| 노드 수 | 1 |
| OS | RHEL 9.4 |
| 디스크 크기 | 500 GB SSD |
| GPU 타입 | NVIDIA A100 80GB |

### GPU 레이블 적용

```bash
# GPU 노드 이름 조회
GPU_NODES=$(kubectl get nodes -l pool=ske-worker-gpu -o jsonpath='{.items[*].metadata.name}')

# GPU 레이블 적용
for node in ${GPU_NODES}; do
  kubectl label node ${node} nvidia.com/gpu.present=true
  echo "GPU 노드 레이블 적용: ${node}"
done
```

### NVIDIA Device Plugin 설치

```bash
# NVIDIA device plugin DaemonSet 적용
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

### DCGM Exporter 설치 (GPU 모니터링)

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

## 2-5단계: GPU MIG (Multi-Instance GPU) 구성

NVIDIA MIG는 단일 A100 GPU를 여러 개의 격리된 GPU 인스턴스로 분할하여 리소스 활용도를 높일 수 있습니다.

### MIG 설정 적용

MIG ConfigMap 적용 (`gpu-mig-configmap.yaml` 참조):

```bash
kubectl apply -f gpu-mig-configmap.yaml
```

### NVIDIA MIG Manager 배포

MIG Manager DaemonSet 적용 (`nvidia-mig-manager.yaml` 참조):

```bash
kubectl apply -f nvidia-mig-manager.yaml
```

### MIG 구성 확인

```bash
# MIG manager 실행 확인
kubectl get pods -n kube-system -l app=nvidia-mig-manager

# GPU 노드에 SSH 접속하여 MIG 인스턴스 확인
# nvidia-smi mig -lgi
# 예상 출력: MIG 인스턴스 표시 (예: 7 x 1g.10gb 또는 3 x 2g.20gb + 1 x 1g.10gb)

# 쿠버네티스에서 GPU 리소스 확인
kubectl describe node -l nvidia.com/gpu.present=true | grep -A 10 "Allocatable"
# nvidia.com/gpu 또는 nvidia.com/mig-* 리소스가 표시되어야 함
```

---

## 2-6단계: 모든 노드 Ready 상태 확인

```bash
# 모든 노드 Ready 상태 확인
kubectl get nodes -o wide

# 예상 출력:
# NAME                    STATUS   ROLES    AGE   VERSION         OS-IMAGE                          CONTAINER-RUNTIME
# ske-worker-general-1    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-2    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-3    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-4    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-general-5    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-asrobot-1    Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30
# ske-worker-gpu-1        Ready    <none>   ...   v1.34.3-ske.p3  Red Hat Enterprise Linux 9.4      containerd://1.7.30

# 레이블 확인
echo "=== 일반 워커 ==="
kubectl get nodes -l pool=ske-worker-general --show-labels

echo "=== ASRobot 워커 ==="
kubectl get nodes -l serverless.daemon=true --show-labels

echo "=== GPU 워커 ==="
kubectl get nodes -l nvidia.com/gpu.present=true --show-labels

# ASRobot 노드 테인트 확인
echo "=== ASRobot 테인트 ==="
kubectl get nodes -l serverless.daemon=true -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.taints}{"\n"}{end}'
```

---

## 검증 체크리스트

| 확인 항목 | 명령어 | 예상 결과 |
|-----------|--------|-----------|
| 클러스터 접근 | `kubectl get nodes` | 모든 노드 표시 |
| 일반 워커 Ready | `kubectl get nodes -l pool=ske-worker-general` | 5개+ 노드 Ready |
| ASRobot 워커 Ready | `kubectl get nodes -l serverless.daemon=true` | 1개+ 노드 Ready |
| ASRobot 테인트 적용 | `kubectl describe node -l serverless.daemon=true \| grep Taint` | `serverless.robot=present:NoSchedule` |
| GPU 워커 Ready | `kubectl get nodes -l nvidia.com/gpu.present=true` | 1개 노드 Ready |
| GPU 플러그인 실행 | `kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds` | Running |
| MIG 구성 | `kubectl get pods -n kube-system -l app=nvidia-mig-manager` | Running |
| K8s 버전 | `kubectl version` | v1.34.x |

---

## 문제 해결

### 노드가 Ready 상태가 되지 않는 경우

```bash
# 노드 상태 확인
kubectl describe node <NODE_NAME> | grep -A 10 "Conditions"

# kubelet 로그 확인 (노드 SSH 접속)
journalctl -u kubelet -f --no-pager | tail -50
```

### GPU가 감지되지 않는 경우

```bash
# GPU 노드에 SSH 접속
nvidia-smi

# NVIDIA 드라이버 버전 확인
cat /proc/driver/nvidia/version

# device plugin 재시작
kubectl delete pods -n kube-system -l name=nvidia-device-plugin-ds
```

### ASRobot Pod Pending (배포 후)

ASRobot Pod이 `FailedScheduling`을 표시하는 경우:

```bash
# 노드 어피니티 일치 확인
kubectl get nodes --show-labels | grep serverless

# 테인트된 노드에서 CSI가 실행 중인지 확인 (4단계 참조)
kubectl get pods -n kube-system -l app=csi-bs-node -o wide
```
