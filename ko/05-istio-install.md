# 5단계: Istio 설치 + NLB 연동

삼성 클라우드 SKE에 Istio 서비스 메시를 설치하고 삼성 클라우드 NLB(네트워크 로드 밸런서)와 연동하는 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| SKE 클러스터 | 모든 노드 풀 실행 중 (2단계) |
| 네트워크/NLB | 방화벽 규칙 구성, 퍼블릭 IP 할당 완료 (3단계) |
| 스토리지 | 블록 및 NFS 스토리지 준비 완료 (4단계) |
| 오프라인 레지스트리 | Istio 차트 및 이미지 미러링 완료 (1단계) |
| Helm | v3.8+ 설치 |

## 환경 변수 설정

```bash
export FQDN="ske.myrobots.co.kr"
export PUBLIC_IP="123.41.32.188"
export PUBLIC_IP_ID="a5168593ce6c44d68e7255606eb07d14"
export TARGET_REGISTRY="<삼성-클라우드-레지스트리-url>"
export ISTIO_VERSION="1.30.2"
```

---

## 5-1단계: Istio Base CRD 설치

오프라인 레지스트리에서 Istio Custom Resource Definition을 설치합니다.

```bash
# istio-system 네임스페이스 생성
kubectl create namespace istio-system

# 오프라인 레지스트리에서 Istio base CRD 설치
helm install istio-base \
  oci://${TARGET_REGISTRY}/helm/istio/base \
  --version ${ISTIO_VERSION} \
  -n istio-system \
  --set defaultRevision=default
```

### CRD 확인

```bash
# Istio CRD 설치 확인
kubectl get crds | grep istio
# 예상 CRD:
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

## 5-2단계: istiod 컨트롤 플레인 설치

```bash
# 오프라인 레지스트리에서 istiod 설치
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

### istiod 확인

```bash
# istiod Pod 실행 확인
kubectl get pods -n istio-system -l app=istiod
# NAME                      READY   STATUS    RESTARTS   AGE
# istiod-xxxxxxxxx-xxxxx    1/1     Running   0          1m

# istiod 서비스 확인
kubectl get svc istiod -n istio-system

# Istio 버전 확인
kubectl get pods -n istio-system -l app=istiod \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

---

## 5-3단계: 삼성 클라우드 NLB와 연동된 Istio Ingress Gateway 배포

삼성 클라우드 전용 NLB 어노테이션이 포함된 Istio Ingress Gateway를 배포합니다.

### Gateway 설치

```bash
# 오프라인 레지스트리에서 Istio gateway 설치
helm install istio-ingressgateway \
  oci://${TARGET_REGISTRY}/helm/istio/gateway \
  --version ${ISTIO_VERSION} \
  -n istio-system \
  --set image="${TARGET_REGISTRY}/istio/proxyv2:${ISTIO_VERSION}" \
  --wait
```

### NLB 서비스 구성 적용

삼성 클라우드 NLB 전용 서비스 구성을 적용합니다 (`istio-ingressgateway-nlb.yaml` 참조):

```bash
kubectl apply -f istio-ingressgateway-nlb.yaml
```

서비스에 포함된 삼성 클라우드 어노테이션:
- `scp-load-balancer-public-ip-enabled: "true"` — 퍼블릭 IP NAT 활성화
- `scp-load-balancer-public-ip-id` — 사전 할당된 퍼블릭 IP UUID 연결
- `scp-load-balancer-source-ranges-firewall-rules: "true"` — 소스 범위 방화벽 규칙 활성화

### NLB 할당 확인

```bash
# 서비스에 External IP 확인
kubectl get svc istio-ingressgateway -n istio-system
# NAME                   TYPE           CLUSTER-IP      EXTERNAL-IP
# istio-ingressgateway   LoadBalancer   172.20.x.x      123.41.32.188

# LoadBalancer 프로비저닝 대기 (수 분 소요될 수 있음)
kubectl get svc istio-ingressgateway -n istio-system -w

# 내부 및 외부 IP 모두 확인
kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}'
# 예상: 192.168.10.x (내부 VIP) 123.41.32.188 (퍼블릭 VIP)
```

> **참고:** 삼성 클라우드 NLB 프로비저닝은 수 분이 소요됩니다. `EXTERNAL-IP`에 퍼블릭 IP가 표시될 때까지 기다리세요.

---

## 5-4단계: TLS 인증서 생성

FQDN에 대한 와일드카드 TLS 인증서를 생성합니다.

### 옵션 A: 자체 서명 인증서 (개발/테스트)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=${FQDN}" \
  -addext "subjectAltName=DNS:${FQDN},DNS:*.${FQDN}"
```

### 옵션 B: CA 서명 인증서 (운영 환경)

CSR을 생성하여 인증 기관에 제출합니다:

```bash
# 개인 키 생성
openssl genrsa -out tls.key 2048

# SAN 포함 CSR 생성
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=${FQDN}" \
  -addext "subjectAltName=DNS:${FQDN},DNS:*.${FQDN}"

# tls.csr을 CA에 제출
# tls.crt (인증서) 및 ca.crt (CA 체인) 수신
echo "CSR을 CA에 제출하고 서명된 인증서를 받으세요"
```

### 옵션 C: Let's Encrypt (인터넷 접근 가능한 경우)

```bash
# certbot 사용
certbot certonly --manual --preferred-challenges dns \
  -d "${FQDN}" -d "*.${FQDN}"

# 인증서 위치: /etc/letsencrypt/live/${FQDN}/
cp /etc/letsencrypt/live/${FQDN}/fullchain.pem tls.crt
cp /etc/letsencrypt/live/${FQDN}/privkey.pem tls.key
cp /etc/letsencrypt/live/${FQDN}/chain.pem ca.crt
```

### 인증서 확인

```bash
# 인증서 상세 확인
openssl x509 -in tls.crt -text -noout | grep -A 2 "Subject Alternative Name"
# 예상: DNS:ske.myrobots.co.kr, DNS:*.ske.myrobots.co.kr

# 키가 인증서와 일치하는지 확인
openssl x509 -noout -modulus -in tls.crt | md5sum
openssl rsa -noout -modulus -in tls.key | md5sum
# 두 MD5 해시가 일치해야 함
```

---

## 5-5단계: TLS Secret 생성

`istio-system` 네임스페이스에 `istio-ingressgateway-certs` Secret을 생성합니다.

> **중요:** Secret에 반드시 `ca.crt`가 포함되어야 합니다. `uipathctl` 도구가 인증서 체인을 검증합니다.

```bash
# CA 서명 인증서의 경우: ca.crt 별도 파일 사용
kubectl create secret generic istio-ingressgateway-certs \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  -n istio-system

# 자체 서명 인증서의 경우 ca.crt를 tls.crt와 동일하게 지정:
# kubectl create secret generic istio-ingressgateway-certs \
#   --from-file=tls.crt=tls.crt \
#   --from-file=tls.key=tls.key \
#   --from-file=ca.crt=tls.crt \
#   -n istio-system
```

### Secret 확인

```bash
# 필요한 모든 키가 포함된 Secret 확인
kubectl get secret istio-ingressgateway-certs -n istio-system \
  -o jsonpath='{.data}' | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
# 예상: ['ca.crt', 'tls.crt', 'tls.key']

# Secret의 인증서가 예상 FQDN과 일치하는지 확인
kubectl get secret istio-ingressgateway-certs -n istio-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject Alternative"
```

---

## 5-6단계: NLB에 External IP 할당 확인

Istio + NLB 전체 스택이 정상 동작하는지 최종 확인합니다.

```bash
# 서비스 상태 확인
kubectl get svc istio-ingressgateway -n istio-system -o wide

# 모든 Istio Pod 실행 확인
kubectl get pods -n istio-system
# 예상:
# istiod-xxxxx                    1/1     Running
# istio-ingressgateway-xxxxx      1/1     Running

# HTTPS 연결 테스트 (자체 서명 인증서의 경우 인증서 오류 표시)
curl -vk https://${PUBLIC_IP} 2>&1 | grep "SSL connection"
# 예상: SSL connection using TLS...

# FQDN으로 테스트 (DNS 구성 후)
curl -vk https://${FQDN} 2>&1 | grep "subject:"
# 예상: subject: CN=ske.myrobots.co.kr

# NodePort 할당 확인
kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{range .spec.ports[*]}{.name}{": "}{.port}{" → NodePort "}{.nodePort}{"\n"}{end}'
# 예상:
# status-port: 15021 → NodePort 3xxxx
# http2: 80 → NodePort 3xxxx
# https: 443 → NodePort 3xxxx
```

---

## 검증 체크리스트

| 확인 항목 | 명령어 | 예상 결과 |
|-----------|--------|-----------|
| Istio CRD | `kubectl get crds \| grep istio \| wc -l` | 10개+ CRD |
| istiod 실행 | `kubectl get pods -n istio-system -l app=istiod` | 1/1 Running |
| Gateway 실행 | `kubectl get pods -n istio-system -l app=istio-ingressgateway` | 1/1 Running |
| NLB External IP | `kubectl get svc istio-ingressgateway -n istio-system` | EXTERNAL-IP에 퍼블릭 IP 표시 |
| TLS Secret | `kubectl get secret istio-ingressgateway-certs -n istio-system` | 존재 |
| Secret 키 | Secret 데이터 키 확인 | ca.crt, tls.crt, tls.key |
| HTTPS 접근 | `curl -vk https://${PUBLIC_IP}` | SSL 핸드셰이크 성공 |

---

## 문제 해결

### NLB가 Pending 상태에 머무르는 경우

```bash
# 서비스 이벤트 확인
kubectl describe svc istio-ingressgateway -n istio-system

# 일반적인 원인:
# - 잘못된 Public IP ID → UUID 확인
# - LB용 서브넷 미구성 → 삼성 클라우드 VPC 설정 확인
# - 방화벽이 LB 프로비저닝 차단 → LB 방화벽 규칙 확인
# - NLB 프로비저닝에 3-5분 소요 → 대기 후 재시도
```

### 인증서 문제

```bash
# 인증서 체인 검증
openssl verify -CAfile ca.crt tls.crt

# 인증서 만료 확인
openssl x509 -in tls.crt -noout -enddate

# 필요 시 Secret 재생성
kubectl delete secret istio-ingressgateway-certs -n istio-system
kubectl create secret generic istio-ingressgateway-certs \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  -n istio-system
```

### Gateway에 트래픽이 도달하지 않는 경우

```bash
# Gateway Pod 로그 확인
kubectl logs -n istio-system -l app=istio-ingressgateway --tail=50

# istiod 로그에서 구성 오류 확인
kubectl logs -n istio-system -l app=istiod --tail=50

# Gateway 리스너 확인
kubectl exec -n istio-system $(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s localhost:15000/listeners | head -20
```

---

## 참고 자료

- [UiPath: 서비스 메시 설치 및 구성](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/installing-and-configuring-the-service-mesh)
- [삼성 클라우드 SKE 로드밸런서](https://docs.e.samsungsdscloud.com/userguide/container/k8s_engine/usage_guide/k8s_typelb_use/)
- [UiPath 호환성 매트릭스](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-openshift/compatibility-matrix)
