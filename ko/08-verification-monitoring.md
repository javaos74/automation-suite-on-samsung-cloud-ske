# 8단계: 검증 및 모니터링

배포 후 검증, 헬스 체크, UiPath Automation Suite의 지속적 모니터링 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| 배포 | `uipathctl manifest apply` 완료 (7단계) |
| ArgoCD | 모든 애플리케이션 동기화 |
| DNS | FQDN이 외부에서 해석 가능 |
| 브라우저 | `https://<FQDN>` 접근 가능 |

## 환경 변수 설정

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"
export ARGOCD_HOST="alm.${FQDN}"
```

---

## 8-1단계: ArgoCD 앱 동기화 상태 확인

모든 ArgoCD 애플리케이션이 **Synced** 및 **Healthy** 상태를 표시해야 합니다.

```bash
# 모든 애플리케이션 상태 목록
kubectl get applications -n argocd

# 비정상 애플리케이션 확인
kubectl get applications -n argocd -o custom-columns=\
NAME:.metadata.name,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status,\
MESSAGE:.status.conditions[0].message

# 예상: 모두 "Synced" 및 "Healthy" 표시
# 요약 집계
echo "=== 애플리케이션 상태 요약 ==="
echo "전체: $(kubectl get applications -n argocd --no-headers | wc -l)"
echo "동기화됨: $(kubectl get applications -n argocd --no-headers | grep -c 'Synced')"
echo "정상: $(kubectl get applications -n argocd --no-headers | grep -c 'Healthy')"
echo "저하됨: $(kubectl get applications -n argocd --no-headers | grep -c 'Degraded')"
echo "진행 중: $(kubectl get applications -n argocd --no-headers | grep -c 'Progressing')"
```

### OutOfSync 애플리케이션 수정

```bash
# 애플리케이션이 OutOfSync 상태에 멈춰 있는 경우 ArgoCD를 통해 강제 동기화
argocd app sync <앱-이름>

# kubectl 사용
kubectl patch application <앱-이름> -n argocd --type merge \
  -p '{"operation": {"sync": {"force": true}}}'
```

---

## 8-2단계: 모든 Pod Running 상태 확인

```bash
# Pod 상태 요약
echo "=== uipath 네임스페이스 Pod 상태 ==="
kubectl get pods -n uipath --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn

# Running이 아닌 Pod 목록 (완료된 Job 제외)
kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded

# CrashLoopBackOff 상태 Pod 확인
kubectl get pods -n uipath | grep -E "CrashLoop|Error|ImagePull"

# Pending 상태 Pod 확인
PENDING_PODS=$(kubectl get pods -n uipath --field-selector=status.phase=Pending --no-headers)
if [ -n "${PENDING_PODS}" ]; then
  echo "=== Pending Pod ==="
  echo "${PENDING_PODS}"
  echo ""
  echo "=== Pending Pod 이벤트 ==="
  for pod in $(echo "${PENDING_PODS}" | awk '{print $1}'); do
    echo "--- ${pod} ---"
    kubectl describe pod ${pod} -n uipath | grep -A 5 "Events:"
  done
fi
```

### Pending Pod 처리

| 원인 | 해결 방법 |
|------|-----------|
| CPU/메모리 부족 | 워커 노드 추가 또는 노드 풀 확장 |
| PVC Pending | StorageClass 및 CSI 드라이버 확인 |
| 노드 어피니티 불일치 | 레이블 확인 (예: ASRobots의 `serverless.daemon=true`) |
| 테인트 미허용 | Pod 스펙의 tolerations 확인 |

```bash
# Pod 상세 진단
kubectl describe pod <pod-이름> -n uipath | tail -30

# 리소스 요청 vs 가용량 확인
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"
```

---

## 8-3단계: `uipathctl health check` 실행

```bash
# 종합 헬스 체크 실행
uipathctl health check

# 상세 출력
uipathctl health check --log-level debug

# 지원 번들 생성 (문제 발견 시)
uipathctl health bundle input-ske.json --versions versions.json
```

### 예상 헬스 체크 결과

모든 체크가 통과해야 합니다:
- 데이터베이스 연결
- Redis 연결
- 오브젝트 스토리지 접근
- 인증서 유효성
- 서비스 엔드포인트 응답
- Pod 상태

---

## 8-4단계: 브라우저를 통한 Automation Suite 접근

```bash
echo "======================================"
echo "  UiPath Automation Suite 접근 정보"
echo "======================================"
echo ""
echo "URL: https://${FQDN}"
echo "사용자명: admin"
echo "비밀번호: (input-ske.json의 admin_password 참조)"
echo ""
echo "======================================"
```

### HTTPS 확인

```bash
# HTTPS 연결 테스트
curl -vk https://${FQDN} 2>&1 | grep "HTTP/"
# 예상: HTTP/2 200 또는 HTTP/1.1 302 (로그인 페이지로 리다이렉트)

# 인증서 확인
curl -vk https://${FQDN} 2>&1 | grep "subject:"
# 예상: subject: CN=ske.myrobots.co.kr

# 로그인 엔드포인트 테스트
curl -sk https://${FQDN}/identity_/.well-known/openid-configuration | python3 -m json.tool | head -10
```

---

## 8-5단계: 브라우저를 통한 ArgoCD 접근

```bash
echo "======================================"
echo "  ArgoCD 접근 정보"
echo "======================================"
echo ""
echo "URL: https://alm.${FQDN}"
echo "사용자명: admin"
echo "비밀번호: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "======================================"
```

### ArgoCD 접근 확인

```bash
# ArgoCD 엔드포인트 테스트
curl -sk https://alm.${FQDN} | grep -i "argocd"

# NLB를 통해 접근할 수 없는 경우 port-forward를 대체로 사용
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## 8-6단계: 조직 생성 및 로그인 확인

1. 브라우저 열기: `https://${FQDN}`
2. 호스트 관리자 자격 증명으로 로그인
3. **관리 > 조직** 메뉴로 이동
4. 새 조직 생성
5. 사용자 추가 및 라이선스 할당
6. 새 사용자 자격 증명으로 로그인 확인

### API를 통한 확인

```bash
# 액세스 토큰 획득
TOKEN=$(curl -sk https://${FQDN}/identity_/connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<client-id>&client_secret=<client-secret>&scope=OR.Default" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Orchestrator API 테스트
curl -sk https://${FQDN}/orchestrator_/api/Status/Get \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool
```

---

## 8-7단계: 모니터링 스크립트

지속적인 헬스 체크를 위해 모니터링 스크립트를 사용합니다:

```bash
# 실행 권한 부여
chmod +x monitoring-scripts.sh

# 전체 헬스 체크 실행
./monitoring-scripts.sh health

# 특정 Pod 로그 확인
./monitoring-scripts.sh logs <pod-이름>

# 이벤트 감시
./monitoring-scripts.sh events

# 리소스 사용량
./monitoring-scripts.sh resources
```

### 빠른 모니터링 명령어

```bash
# Pod 상태 개요
kubectl get pods -n uipath -o wide --sort-by='.status.startTime'

# 리소스 소비량
kubectl top pods -n uipath --sort-by=memory | head -20

# 노드 리소스 사용량
kubectl top nodes

# 최근 이벤트 (최근 30분)
kubectl get events -n uipath --sort-by='.lastTimestamp' \
  --field-selector type=Warning | tail -20

# PVC 상태
kubectl get pvc -n uipath

# 서비스 엔드포인트
kubectl get endpoints -n uipath | head -20
```

---

## 8-8단계: 문제 해결 가이드

### 일반적인 문제 및 해결 방법

#### 문제: Identity Server 503

```bash
# identity Pod 확인
kubectl get pods -n uipath -l app=identity

# identity 로그 확인
kubectl logs -n uipath -l app=identity --tail=30

# identity Pod에서 SQL 연결 확인
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=identity -o jsonpath='{.items[0].metadata.name}') \
  -- curl -v telnet://${SQL_HOST}:1433
```

#### 문제: Orchestrator CrashLoopBackOff

```bash
# orchestrator 로그 확인
kubectl logs -n uipath -l app=orchestrator --tail=50 --previous

# 일반적인 원인:
# - SQL 연결 문자열 오류
# - Redis 연결 실패
# - 인증서 신뢰 문제
```

#### 문제: ASRobot Pod Pending

```bash
# 노드 레이블 확인
kubectl get nodes --show-labels | grep serverless

# ASRobot Pod의 tolerations 확인
kubectl get pods -n uipath -l app=asrobots -o yaml | grep -A 5 tolerations

# 테인트 노드에서 CSI 확인
kubectl get pods -n kube-system -l app=csi-bs-node -o wide
```

#### 문제: ImagePullBackOff

```bash
# 이미지 상세 확인
kubectl describe pod <pod-이름> -n uipath | grep "Image:"

# 오프라인 레지스트리에 이미지 존재 여부 확인
# docker pull ${TARGET_REGISTRY}/<이미지-경로>

# imagePullSecrets 확인
kubectl get pod <pod-이름> -n uipath -o jsonpath='{.spec.imagePullSecrets}'
```

#### 문제: PVC가 Pending에 멈춤

```bash
# PVC 이벤트 확인
kubectl describe pvc <pvc-이름> -n uipath

# StorageClass 확인
kubectl get sc

# CSI 컨트롤러 로그 확인
kubectl logs -n kube-system -l app=csi-bs-controller --tail=20
```

#### 문제: VirtualService 라우팅 불가

```bash
# VirtualService 구성 확인
kubectl get vs -n uipath

# Istio 프록시 로그 확인
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=30

# Gateway 리소스 확인
kubectl get gateway -n uipath
kubectl describe gateway main-gateway -n uipath
```

#### 문제: 서비스 간 통신 실패 (401/503)

```bash
# 일반적으로 클러스터 내에서 FQDN을 해석할 수 없음을 의미
# CoreDNS 구성 확인
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=orchestrator -o jsonpath='{.items[0].metadata.name}') \
  -- nslookup ${FQDN}

# identity server 응답 확인
curl -sk https://${FQDN}/identity_/.well-known/openid-configuration

# 인증서 신뢰 확인
kubectl exec -n uipath $(kubectl get pod -n uipath -l app=orchestrator -o jsonpath='{.items[0].metadata.name}') \
  -- curl -v https://${FQDN}/identity_/.well-known/openid-configuration
```

---

## 지속적 모니터링 체크리스트

| 확인 항목 | 주기 | 명령어 |
|-----------|------|--------|
| Pod 상태 | 5분마다 | `kubectl get pods -n uipath --field-selector=status.phase!=Running,status.phase!=Succeeded` |
| ArgoCD 동기화 | 10분마다 | `kubectl get applications -n argocd` |
| 노드 리소스 | 15분마다 | `kubectl top nodes` |
| 이벤트/경고 | 10분마다 | `kubectl get events -n uipath --field-selector type=Warning` |
| 인증서 만료 | 주간 | `openssl x509 -in tls.crt -noout -enddate` |
| PVC 사용량 | 일간 | `kubectl get pvc -n uipath` |
| 헬스 체크 | 일간 | `uipathctl health check` |

---

## 참고 자료

- [UiPath Automation Suite 문제 해결](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
- [UiPath 헬스 체크](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
