# 7단계: UiPath Automation Suite 설치

`uipathctl`을 사용하여 삼성 클라우드 SKE에 UiPath Automation Suite를 실제 배포하는 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| Istio | NLB 및 TLS 구성 완료 (5단계) |
| ArgoCD | 레지스트리 연결 완료 (6단계) |
| 스토리지 | 블록 및 NFS 스토리지 준비 완료 (4단계) |
| 외부 의존성 | SQL Server, Redis, 오브젝트 스토리지 접근 가능 |
| uipathctl | 관리 머신에 바이너리 설치 완료 |
| input.json | SKE 전용 설정으로 준비 완료 |
| versions.json | UiPath 버전 매니페스트 파일 |

## 환경 변수 설정

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"
export WORK_DIR="/opt/uipath-install"
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
```

---

## 7-1단계: 네임스페이스 생성

세 개의 네임스페이스가 필요합니다. 두 개는 이전 단계에서 이미 생성되어 있어야 합니다:

| 네임스페이스 | 생성 위치 | 용도 |
|-------------|-----------|------|
| `istio-system` | 5단계 (5-1단계) | Istio 컨트롤 플레인 및 인그레스 게이트웨이 |
| `argocd` | 6단계 (6-1단계) | ArgoCD GitOps 엔진 |
| `uipath` | **이 단계** | UiPath Automation Suite 서비스 |

```bash
# 이전 단계에서 생성된 네임스페이스 존재 확인
kubectl get ns istio-system   # 5단계, 5-1단계에서 생성
kubectl get ns argocd         # 6단계, 6-1단계에서 생성

# uipath 네임스페이스 생성 (이 단계에서 새로 생성)
kubectl create ns uipath

# 세 개 네임스페이스 모두 확인
kubectl get ns istio-system argocd uipath
```

> **참고:** `istio-system` 또는 `argocd` 네임스페이스가 없는 경우 각각 5단계 또는 6단계를 다시 확인하세요. 해당 단계를 건너뛰지 마세요.

---

## 7-2단계: Priority Class용 ResourceQuota 적용

SKE는 system-critical priority class를 사용하는 네임스페이스에 대해 리소스 할당량을 강제할 수 있습니다. Pod 스케줄링 실패를 방지하기 위해 할당량을 적용합니다.

```bash
kubectl apply -f resource-quotas.yaml
```

### 할당량 확인

```bash
# 각 네임스페이스의 할당량 확인
kubectl get resourcequota -n istio-system
kubectl get resourcequota -n argocd
kubectl get resourcequota -n uipath
```

---

## 7-3단계: 클러스터 내 FQDN 해석을 위한 CoreDNS 구성

UiPath Automation Suite는 클러스터 내부 Pod에서 FQDN을 해석할 수 있어야 합니다. 모든 서비스 간 통신은 외부 FQDN을 사용합니다 (헤어핀 패턴).

### 현재 CoreDNS 구성 확인

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

### 커스텀 CoreDNS 구성 적용

```bash
kubectl apply -f coredns-custom-config.yaml
```

### CoreDNS 재시작

```bash
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns
```

---

## 7-4단계: 클러스터 내 DNS 해석 확인

> **중요:** `manifest apply` 실행 전에 반드시 이 확인을 수행하세요. Pod 내에서 DNS 해석이 실패하면 모든 서비스 간 통신이 런타임에 실패합니다.

```bash
# 기본 FQDN 해석 테스트
kubectl run dns-test --rm -it --image=busybox --restart=Never -- \
  nslookup ${FQDN}
# 예상: Name: ske.myrobots.co.kr  Address: 123.41.32.188

# 와일드카드 서브도메인 해석 테스트
kubectl run dns-test2 --rm -it --image=busybox --restart=Never -- \
  nslookup alm.${FQDN}
# 예상: Name: alm.ske.myrobots.co.kr  Address: 123.41.32.188

# 장기 실행 Pod에서 테스트 (더 안정적)
kubectl run dns-debug --image=busybox --restart=Never -- sleep 3600
kubectl exec dns-debug -- nslookup ${FQDN}
kubectl exec dns-debug -- nslookup alm.${FQDN}
kubectl delete pod dns-debug
```

둘 다 퍼블릭 IP (`123.41.32.188`)로 해석되어야 합니다. 그렇지 않으면 CoreDNS 구성을 다시 확인하세요.

---

## 7-5단계: input.json 준비

`input.json` 파일은 UiPath Automation Suite 배포의 중앙 설정 파일입니다. `input-ske.json`을 최종 설정으로 사용합니다.

### SKE 전용 주요 설정

```json
{
  "registries": {
    "docker": { "url": "<삼성-클라우드-레지스트리-url>" },
    "helm": { "url": "<삼성-클라우드-레지스트리-url>" }
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

### input.json 검증

```bash
# JSON 문법 확인
python3 -m json.tool input-ske.json > /dev/null
echo "JSON 문법 정상"

# 주요 필드 확인
python3 -c "
import json
with open('input-ske.json') as f:
    cfg = json.load(f)
print(f'FQDN: {cfg[\"fqdn\"]}')
print(f'네임스페이스: {cfg[\"namespace\"]}')
print(f'프로파일: {cfg[\"profile\"]}')
print(f'클러스터 타입: {cfg[\"cluster_type\"]}')
print(f'스토리지 RWO: {cfg[\"storage_class\"]}')
print(f'스토리지 RWX: {cfg[\"storage_class_name_with_rwx_support\"]}')
print(f'제외 컴포넌트: {cfg[\"exclude_components\"]}')
"
```

---

## 7-6단계: `uipathctl prereq create` 실행

이 명령은 SQL Server에 필요한 데이터베이스와 오브젝트 스토리지에 버킷을 생성합니다.

```bash
uipathctl prereq create input-ske.json \
  --versions versions.json \
  --log-level debug
```

### 예상 결과

- 활성화된 각 서비스에 대한 데이터베이스 생성 (Orchestrator, Platform, AI Center 등)
- 오브젝트 스토리지 버킷 생성
- 5-10분 소요

### CORS 오류 처리

오브젝트 스토리지에서 CORS 관련 오류로 명령이 실패하는 경우:

```bash
# 삼성 클라우드 오브젝트 스토리지는 S3 API를 통한 put-bucket-cors를 지원하지 않을 수 있음
# 삼성 클라우드 콘솔에서 수동으로 CORS 구성:
# 1. 스토리지 > 오브젝트 스토리지 > 버킷 > CORS 설정 이동
# 2. CORS 규칙 추가:
#    - AllowedOrigins: https://ske.myrobots.co.kr
#    - AllowedMethods: GET, HEAD, PUT, POST, DELETE
#    - AllowedHeaders: *
#    - MaxAgeSeconds: 3000
```

### 데이터베이스 생성 확인

```bash
# SQL Server에 연결하여 데이터베이스 목록 확인
kubectl run sql-check --rm -it --image=mcr.microsoft.com/mssql-tools:latest --restart=Never -- \
  /opt/mssql-tools/bin/sqlcmd -S ${SQL_HOST},${SQL_PORT} -U ${SQL_USER} -P "${SQL_PASSWORD}" \
  -Q "SELECT name FROM sys.databases WHERE name LIKE 'AutomationSuite%'"
```

---

## 7-7단계: `uipathctl prereq run` 실행

배포 전에 모든 사전 요구 사항이 충족되었는지 검증합니다.

```bash
uipathctl prereq run input-ske.json \
  --versions versions.json \
  --log-level debug
```

### DNS 체크 실패 처리

로컬 DNS 체크가 실패하는 경우 (내부 도메인에서 흔함):

```bash
# 로컬 DNS 체크 건너뛰기 (클러스터 내 DNS는 7-4단계에서 이미 확인)
uipathctl prereq run input-ske.json \
  --versions versions.json \
  --log-level debug \
  --excluded "DNS(fqdn=alm.${FQDN})"
```

### 예상 체크 항목

| 체크 | 설명 |
|------|------|
| SQL 연결 | SQL Server에 연결 |
| Redis 연결 | TLS로 Redis에 연결 |
| 오브젝트 스토리지 | 버킷 접근 확인 |
| StorageClass | RWO 및 RWX 클래스 존재 확인 |
| 인증서 | TLS Secret 검증 |
| DNS | FQDN 해석 (내부 도메인의 경우 로컬에서 실패할 수 있음) |
| 쿠버네티스 버전 | 호환성 확인 |

모든 체크가 통과해야 합니다 (내부 도메인의 로컬 DNS 체크 제외 가능).

---

## 7-8단계: `uipathctl manifest apply` 실행

UiPath Automation Suite를 배포합니다.

```bash
uipathctl manifest apply input-ske.json \
  --versions versions.json
```

### 예상 동작

1. 각 UiPath 컴포넌트에 대한 ArgoCD Application 생성
2. ArgoCD가 OCI 레지스트리에서 Helm 차트 동기화
3. `uipath` 네임스페이스에 Pod 배포 시작
4. 활성화된 서비스에 따라 **30-60분** 소요

### 진행 상황 모니터링

두 번째 터미널을 열어 모니터링합니다:

```bash
# ArgoCD 애플리케이션 상태 감시
watch -n 10 "kubectl get applications -n argocd"

# Pod 배포 진행 상황 감시
watch -n 10 "kubectl get pods -n uipath --sort-by=.status.phase | tail -30"

# 상태별 Pod 수 확인
watch -n 10 "echo 'Running:' && kubectl get pods -n uipath --field-selector=status.phase=Running --no-headers | wc -l && echo 'Pending:' && kubectl get pods -n uipath --field-selector=status.phase=Pending --no-headers | wc -l"
```

---

## 7-9단계: ArgoCD UI 및 kubectl을 통한 모니터링

### ArgoCD UI 모니터링

```bash
# ArgoCD UI 접근
# VirtualService가 동작하는 경우:
echo "ArgoCD URL: https://alm.${FQDN}"

# 그렇지 않으면 port-forward:
kubectl port-forward svc/argocd-server -n argocd 8080:443

# admin 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
```

ArgoCD UI에서:
- 모든 애플리케이션이 **Synced** 상태여야 함
- 상태가 **Healthy**여야 함 (초기 배포 시 시간 소요 가능)
- 개별 애플리케이션의 오류 확인

### kubectl 모니터링

```bash
# 전체 상태
kubectl get pods -n uipath -o wide

# 실패한 Pod 확인
kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded

# 이슈 관련 이벤트 확인
kubectl get events -n uipath --sort-by='.lastTimestamp' | tail -20

# 특정 Pod 이슈 확인
kubectl describe pod <pod-이름> -n uipath

# 실패한 Pod의 컨테이너 로그 확인
kubectl logs <pod-이름> -n uipath -c <컨테이너-이름> --tail=50
```

### 완료 대기

```bash
# 모든 애플리케이션이 동기화 및 정상 상태가 될 때까지 대기
while true; do
  TOTAL=$(kubectl get applications -n argocd --no-headers | wc -l)
  HEALTHY=$(kubectl get applications -n argocd --no-headers | grep -c "Healthy")
  SYNCED=$(kubectl get applications -n argocd --no-headers | grep -c "Synced")
  echo "$(date): 애플리케이션 - 전체: ${TOTAL}, 정상: ${HEALTHY}, 동기화: ${SYNCED}"
  if [ "${HEALTHY}" -eq "${TOTAL}" ] && [ "${SYNCED}" -eq "${TOTAL}" ]; then
    echo "모든 애플리케이션이 정상이고 동기화되었습니다!"
    break
  fi
  sleep 30
done
```

---

## 배포 후 참고 사항

### 배포된 서비스

성공적인 배포 후 다음 ArgoCD 애플리케이션이 생성됩니다:

| 애플리케이션 | 설명 |
|-------------|------|
| `orchestrator` | UiPath Orchestrator |
| `platform` | 플랫폼 서비스 (Identity, Portal) |
| `aicenter` | AI Center |
| `asrobots` | Automation Suite Robots |
| `ecs` | Enterprise Content Services |
| `studioweb` | Studio Web |
| `maestro` | Maestro (프로세스 오케스트레이션) |
| `llmgateway` | LLM Gateway |
| `agents` | UiPath Agents |
| `agenthub` | Agent Hub |
| `istio-configure` | Istio 라우팅 구성 |
| `network-configure` | 네트워크 정책 및 게이트웨이 |

### 배포 중 일반적인 문제

| 문제 | 원인 | 해결 방법 |
|------|------|-----------|
| Pod ImagePullBackOff | 오프라인 레지스트리에 이미지 없음 | 누락된 이미지 미러링 |
| Pod Pending (노드 없음) | 리소스 부족 | 워커 노드 추가 |
| Pod CrashLoopBackOff | 설정 오류 | 로그에서 상세 원인 확인 |
| PVC Pending | StorageClass 문제 | CSI 및 SC 확인 |
| ASRobot Pending | 노드 레이블 없음 | `serverless.daemon=true` 레이블 추가 |

---

## 참고 자료

- [UiPath 설치 가이드 (EKS/AKS)](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
- [UiPath 사이징 계산기](https://docs.uipath.com/automation-suite/2025.10/calculator)
