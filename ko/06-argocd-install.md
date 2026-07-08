# 6단계: ArgoCD 설치 + NLB 공유

삼성 클라우드 SKE에 ArgoCD를 설치하고 Istio Ingress Gateway NLB를 공유하여 외부 접근을 구성하는 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| Istio | NLB 동작 확인 완료 (5단계) |
| TLS 인증서 | `*.${FQDN}`을 포함하는 와일드카드 인증서 |
| 오프라인 레지스트리 | ArgoCD 차트 및 이미지 미러링 완료 (1단계) |
| DNS | `alm.${FQDN}`이 퍼블릭 IP로 해석 (3단계) |

## 환경 변수 설정

```bash
export FQDN="ske.myrobots.co.kr"
export ARGOCD_HOST="alm.${FQDN}"
export TARGET_REGISTRY="<삼성-클라우드-레지스트리-url>"
export ARGOCD_VERSION="10.1.1"
```

---

## 6-1단계: Helm을 통한 ArgoCD 설치

오프라인 레지스트리에서 ArgoCD를 설치합니다. 서비스 타입은 ClusterIP로 설정합니다 (NLB 접근은 Istio VirtualService를 통해 처리).

```bash
# 네임스페이스 생성
kubectl create namespace argocd

# 오프라인 레지스트리에서 ArgoCD 설치
helm install argocd \
  oci://${TARGET_REGISTRY}/helm/argo/argo-cd \
  --version ${ARGOCD_VERSION} \
  -n argocd \
  -f argocd-values.yaml \
  --wait
```

### ArgoCD 설치 확인

```bash
# 모든 ArgoCD Pod 실행 확인
kubectl get pods -n argocd
# 예상 Pod:
# argocd-application-controller-xxxxx   1/1   Running
# argocd-repo-server-xxxxx              1/1   Running
# argocd-server-xxxxx                   1/1   Running
# argocd-redis-xxxxx                    1/1   Running
# argocd-dex-server-xxxxx               1/1   Running

# 초기 admin 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""

# ArgoCD 서버 서비스 확인
kubectl get svc argocd-server -n argocd
# TYPE이 ClusterIP여야 함
```

---

## 6-2단계: UiPath AppProject 생성

UiPath 애플리케이션을 위한 전용 ArgoCD AppProject를 생성합니다.

```bash
kubectl apply -f argocd-appproject.yaml
```

### AppProject 확인

```bash
# AppProject 생성 확인
kubectl get appproject uipath -n argocd

# 프로젝트 상세 확인
kubectl describe appproject uipath -n argocd
```

---

## 6-3단계: ArgoCD VirtualService 생성 (NLB 공유)

ArgoCD 전용 LoadBalancer 서비스를 별도로 생성하는 대신, VirtualService를 통해 기존 Istio Ingress Gateway NLB를 공유합니다.

### Gateway 리소스 생성

Gateway는 보통 UiPath의 `network-configure` 컴포넌트가 생성하지만, 설치 전에 필요한 경우:

```bash
# main-gateway가 이미 존재하는지 확인
kubectl get gateway main-gateway -n uipath 2>/dev/null

# 존재하지 않으면 UiPath 배포 후 VirtualService가 참조할 예정
# 배포 전 ArgoCD 접근이 필요한 경우 port-forward 사용:
# kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### VirtualService 적용

```bash
kubectl apply -f argocd-virtualservice.yaml
```

### VirtualService 확인

```bash
# VirtualService 생성 확인
kubectl get virtualservice argocd-vs -n argocd

# 라우팅 구성 확인
kubectl get virtualservice argocd-vs -n argocd -o yaml
```

---

## 6-4단계: ArgoCD에 OCI 레지스트리 연결

삼성 클라우드 프라이빗 레지스트리를 ArgoCD의 Helm OCI 리포지토리 소스로 연결합니다.

### 옵션 A: ArgoCD CLI 사용

```bash
# ArgoCD CLI 설치 (점프 서버에서)
# 다운로드: https://github.com/argoproj/argo-cd/releases

# ArgoCD 로그인 (초기에는 port-forward 사용)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

argocd login localhost:8080 --username admin --password "${ARGOCD_PASSWORD}" --insecure

# OCI 리포지토리 추가
argocd repo add ${TARGET_REGISTRY} \
  --type helm \
  --name samsung-registry \
  --enable-oci \
  --username ${REGISTRY_USERNAME} \
  --password ${REGISTRY_PASSWORD} \
  --project uipath
```

### 옵션 B: Kubernetes Secret 직접 생성

```bash
# 리포지토리 Secret 직접 생성
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

### 리포지토리 연결 확인

```bash
# 리포지토리 연결 확인
argocd repo list

# kubectl을 통한 확인
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository
```

---

## 6-5단계: RBAC 구성 (Cluster-Admin을 사용하지 않는 경우)

제한된 권한을 사용하는 경우 필요한 RBAC 바인딩을 부여합니다.

```bash
# ArgoCD 네임스페이스 접근을 위한 Role 생성
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

# 서비스 어카운트에 Role 바인딩
kubectl -n argocd create rolebinding secret-binding \
  --role=argo-secret-role --serviceaccount=uipath:uipathadmin

kubectl -n argocd create rolebinding uipath-application-manager-rolebinding \
  --role=uipath-application-manager --serviceaccount=uipath:uipathadmin
```

> **참고:** 전용 클러스터에서 권장하는 Cluster Admin 권한을 사용하는 경우 이 단계를 건너뛰세요.

---

## 6-6단계: `alm.<FQDN>`을 통한 ArgoCD UI 접근 확인

### UiPath 배포 전 (Port Forward)

UiPath 배포 전, Gateway 리소스가 존재하지 않는 경우:

```bash
# Port-forward를 통한 ArgoCD 로컬 접근
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 브라우저 접근: https://localhost:8080
# 사용자명: admin
# 비밀번호: (6-1단계에서 확인한 값)
```

### UiPath 배포 후 (NLB 경유)

UiPath 배포 후 `main-gateway`가 존재하는 경우:

```bash
# VirtualService가 올바르게 라우팅되는지 확인
curl -vk https://alm.${FQDN} 2>&1 | grep "HTTP/"
# 예상: HTTP/2 200 또는 HTTP/1.1 200

# 브라우저 접근
echo "ArgoCD URL: https://alm.${FQDN}"
echo "사용자명: admin"
echo "비밀번호: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

---

## 아키텍처: NLB 공유

```
                          ┌─────────────────────────────┐
                          │  삼성 클라우드 NLB            │
                          │  퍼블릭 IP: 123.41.32.188   │
                          │  포트: 80, 443              │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │  Istio Ingress Gateway      │
                          │  (NodePort 서비스)           │
                          └──────────────┬──────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                     │
         ┌──────────▼──────────┐  ┌─────▼─────┐  ┌──────────▼──────────┐
         │호스트: ske.myrobots │  │호스트: alm.│  │호스트: *.ske.myro...│
         │→ UiPath 서비스      │  │→ ArgoCD    │  │→ 기타 서비스        │
         │(VirtualServices)    │  │(VS: argocd │  │(VirtualServices)    │
         └─────────────────────┘  │    -vs)    │  └─────────────────────┘
                                  └────────────┘
```

---

## 검증 체크리스트

| 확인 항목 | 명령어 | 예상 결과 |
|-----------|--------|-----------|
| ArgoCD Pod 실행 | `kubectl get pods -n argocd` | 모두 Running |
| ArgoCD 서버 ClusterIP | `kubectl get svc argocd-server -n argocd` | ClusterIP 타입 |
| AppProject 생성 | `kubectl get appproject uipath -n argocd` | 존재 |
| VirtualService 생성 | `kubectl get vs argocd-vs -n argocd` | 존재 |
| 레지스트리 연결 | `argocd repo list` | samsung-cloud-registry 연결됨 |
| UI 접근 | `curl -k https://alm.${FQDN}` | HTTP 200 |

---

## 문제 해결

### NLB를 통해 ArgoCD UI에 접근할 수 없는 경우

```bash
# VirtualService가 올바른 gateway에 연결되었는지 확인
kubectl get vs argocd-vs -n argocd -o jsonpath='{.spec.gateways}'

# gateway 존재 확인
kubectl get gateway main-gateway -n uipath

# Istio 프록시 로그에서 라우팅 오류 확인
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=20 | grep "alm"

# 대체: port-forward 사용
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### ArgoCD가 OCI 레지스트리에서 Pull할 수 없는 경우

```bash
# 리포지토리 Secret 확인
kubectl get secret uipath-oci-registry -n argocd -o yaml

# ArgoCD repo-server 로그 확인
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --tail=30

# 클러스터에서 레지스트리 접근 테스트
kubectl run reg-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" https://${TARGET_REGISTRY}/v2/_catalog
```

### 애플리케이션 Sync 실패

```bash
# 애플리케이션 상태 확인
kubectl get applications -n argocd

# 실패한 애플리케이션 상세 확인
kubectl describe application <앱-이름> -n argocd

# ArgoCD application controller 로그 확인
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller --tail=50
```

---

## 참고 자료

- [ArgoCD Helm 차트](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [ArgoCD OCI 리포지토리](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#oci-registries)
- [UiPath ArgoCD 구성](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
