# 4단계: 스토리지 및 외부 의존성 구성

UiPath Automation Suite를 위한 스토리지 클래스 구성 및 외부 의존성(SQL Server, Redis, 오브젝트 스토리지) 프로비저닝 가이드입니다.

## 사전 요구 사항

| 항목 | 요구 사항 |
|------|-----------|
| SKE 클러스터 | 모든 노드 풀 실행 중 (2단계) |
| 네트워크 | 방화벽 규칙 구성 완료 (3단계) |
| NFS 서버 | 익스포트 경로가 구성된 NFS 서버 프로비저닝 완료 |
| SQL Server | 클러스터에서 접근 가능한 상태로 프로비저닝 완료 |
| Redis | TLS 활성화된 상태로 프로비저닝 완료 |
| 오브젝트 스토리지 | 삼성 클라우드 오브젝트 스토리지 버킷 생성 완료 |

## 환경 변수 설정

```bash
export FQDN="ske.myrobots.co.kr"
export NAMESPACE="uipath"

# NFS 서버
export NFS_SERVER="<nfs-서버-ip>"
export NFS_PATH="/exported/path"

# SQL Server
export SQL_HOST="<sql-서버-호스트>"
export SQL_PORT="1433"
export SQL_USER="uipath"
export SQL_PASSWORD="<sql-비밀번호>"

# Redis
export REDIS_HOST="<redis-호스트>"
export REDIS_PORT="6380"
export REDIS_PASSWORD="<redis-비밀번호>"

# 오브젝트 스토리지 (삼성 클라우드 S3 호환)
export S3_FQDN="object-store.kr-west1.e.samsungsdscloud.com"
export S3_PORT="443"
export S3_ACCESS_KEY="<access-key>"
export S3_SECRET_KEY="<secret-key>"
export S3_REGION="kr-west1"
```

---

## 4-1단계: 블록 스토리지(bs-ssd) 확인

삼성 클라우드 SKE에는 블록 스토리지 CSI 드라이버(`bs.csi.samsungsdscloud.com`)가 사전 설치되어 있습니다.

```bash
# CSI 드라이버 설치 확인
kubectl get csidrivers
# 예상: bs.csi.samsungsdscloud.com

# StorageClass 존재 확인
kubectl get storageclasses
# 예상:
# NAME                           PROVISIONER                    RECLAIMPOLICY
# bs-ssd                         bs.csi.samsungsdscloud.com     Delete
# bs-ssd-retain                  bs.csi.samsungsdscloud.com     Retain

# PVC 생성 테스트
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-bs-ssd
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: bs-ssd
  resources:
    requests:
      storage: 1Gi
EOF

# PVC Bound 확인
kubectl get pvc test-bs-ssd
# STATUS가 "Bound"여야 함

# 테스트 PVC 정리
kubectl delete pvc test-bs-ssd
```

---

## 4-2단계: CSI DaemonSet Toleration 패치 (테인트된 노드용)

`csi-bs-node` DaemonSet은 테인트된 ASRobot 노드를 포함한 모든 노드에서 실행되어야 합니다. 이 패치가 없으면 ASRobot 노드의 PVC가 다음 오류로 실패합니다:
```
no topology key found on CSINode ske-worker-asrobot-*
```

### 패치 적용

```bash
# 방법 A: 패치 파일 사용 (권장)
kubectl patch daemonset csi-bs-node -n kube-system \
  --type merge --patch-file csi-bs-node-toleration-patch.yaml

# 방법 B: 인라인 패치
kubectl patch ds csi-bs-node -n kube-system --type merge \
  -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'
```

### 패치 확인

```bash
# 1) DaemonSet이 모든 노드에서 실행 중인지 확인 (DESIRED == 전체 워커 수)
kubectl get ds csi-bs-node -n kube-system

# 2) 테인트된 ASRobot 노드에서 Pod 실행 확인
kubectl get pods -n kube-system -l app=csi-bs-node -o wide | grep asrobot

# 3) ASRobot 노드에 CSINode 토폴로지 키 등록 확인
ASROBOT_NODE=$(kubectl get nodes -l serverless.daemon=true -o jsonpath='{.items[0].metadata.name}')
kubectl get csinode ${ASROBOT_NODE} \
  -o jsonpath='{range .spec.drivers[*]}{.name}{" | "}{.topologyKeys}{"\n"}{end}'
# 예상: bs.csi.samsungsdscloud.com | ["topology.bs.csi.samsungsdscloud.com/zone"]
```

---

## 4-3단계: NFS Subdir External Provisioner 설치

UiPath Automation Suite는 StudioWeb, ECS 등의 서비스에 ReadWriteMany(RWX) 스토리지가 필요합니다. RWX 지원을 위해 NFS를 사용합니다.

### 오프라인 레지스트리에서 설치

```bash
# Helm 레지스트리 로그인
helm registry login ${TARGET_REGISTRY} -u ${REGISTRY_USERNAME} -p ${REGISTRY_PASSWORD}

# values 파일을 사용하여 NFS 프로비저너 설치
helm install nfs-provisioner \
  oci://${TARGET_REGISTRY}/helm/nfs/nfs-subdir-external-provisioner \
  --namespace nfs-system \
  --create-namespace \
  -f nfs-provisioner-values.yaml
```

### NFS 프로비저너 확인

```bash
# 프로비저너 Pod 실행 확인
kubectl get pods -n nfs-system

# 생성된 StorageClass 확인
kubectl get storageclasses | grep nfs
# 예상:
# nfs-subdir-external-sc          k8s-sigs.io/nfs-subdir-external-provisioner   Delete
# nfs-subdir-external-sc-retain   k8s-sigs.io/nfs-subdir-external-provisioner   Retain

# RWX PVC 생성 테스트
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-rwx
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-subdir-external-sc
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-nfs-rwx
# STATUS가 "Bound"여야 함

# 정리
kubectl delete pvc test-nfs-rwx
```

---

## 4-4단계: SQL Server 프로비저닝

UiPath Automation Suite는 모든 제품 데이터베이스에 Microsoft SQL Server가 필요합니다.

### 요구 사항

| 항목 | 사양 |
|------|------|
| 버전 | SQL Server 2019 또는 2022 (Standard/Enterprise) |
| vCPU | 8+ (운영 환경) |
| 메모리 | 32 GB+ (운영 환경) |
| 스토리지 | 500 GB SSD |
| TLS | 활성화 |
| 인증 | SQL 인증 |
| 접근성 | SKE 워커 노드에서 접근 가능 |

### SQL Server 연결 확인

```bash
# 클러스터 내부 Pod에서 확인
kubectl run sql-test --rm -it --image=mcr.microsoft.com/mssql-tools:latest --restart=Never -- \
  /opt/mssql-tools/bin/sqlcmd -S ${SQL_HOST},${SQL_PORT} -U ${SQL_USER} -P "${SQL_PASSWORD}" \
  -Q "SELECT @@VERSION"

# 간단한 TCP 테스트
kubectl run tcp-test --rm -it --image=busybox --restart=Never -- \
  nc -zv ${SQL_HOST} ${SQL_PORT}
```

### SQL Server 연결 문자열 형식

```
Server=tcp:<SQL_HOST>,1433;Initial Catalog=DB_NAME_PLACEHOLDER;Persist Security Info=False;User Id=<SQL_USER>;Password='<SQL_PASSWORD>';MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Max Pool Size=100;
```

> **참고:** `DB_NAME_PLACEHOLDER`는 `uipathctl prereq create` 실행 시 자동으로 치환됩니다.

---

## 4-5단계: Redis 프로비저닝

### 요구 사항

| 항목 | 사양 |
|------|------|
| 버전 | Redis 6.x 또는 7.x |
| 모드 | Standalone 또는 Sentinel (클러스터 모드 미지원) |
| 메모리 | 4 GB+ (운영 환경) |
| TLS | 활성화 (포트 6380) |
| 인증 | 비밀번호 필수 |
| 접근성 | SKE 워커 노드에서 접근 가능 |

### Redis 연결 확인

```bash
# 클러스터에서 TCP 연결 테스트
kubectl run redis-test --rm -it --image=busybox --restart=Never -- \
  nc -zv ${REDIS_HOST} ${REDIS_PORT}

# TLS 포함 전체 Redis 테스트
kubectl run redis-test --rm -it --image=redis:7-alpine --restart=Never -- \
  redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} --tls -a "${REDIS_PASSWORD}" PING
# 예상: PONG
```

---

## 4-6단계: 삼성 클라우드 오브젝트 스토리지 구성

삼성 클라우드 오브젝트 스토리지는 S3 호환 API 접근을 제공합니다.

### 요구 사항

| 항목 | 사양 |
|------|------|
| 엔드포인트 | `object-store.kr-west1.e.samsungsdscloud.com` |
| 포트 | 443 (HTTPS) |
| 프로토콜 | S3 호환 API |
| 인증 | Access Key + Secret Key |
| 버킷 | 사전 생성 또는 uipathctl을 통한 자동 생성 |

### 오브젝트 스토리지 버킷 생성

1. 삼성 클라우드 콘솔에 로그인
2. **스토리지 > 오브젝트 스토리지** 메뉴로 이동
3. 버킷 생성 (예: `as-bucket`)
4. 접근 자격 증명 생성 (Access Key + Secret Key)

### 오브젝트 스토리지 연결 확인

```bash
# 클러스터 내에서 AWS CLI (S3 호환)를 사용한 테스트
kubectl run s3-test --rm -it --image=amazon/aws-cli:latest --restart=Never -- \
  aws s3 ls \
  --endpoint-url https://${S3_FQDN} \
  --region ${S3_REGION}

# curl을 사용한 테스트
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -v https://${S3_FQDN}
```

### 버킷 CORS 구성

```bash
# 브라우저 기반 접근을 위한 CORS 구성 필수
aws s3api put-bucket-cors \
  --bucket as-bucket \
  --endpoint-url https://${S3_FQDN} \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["POST", "GET", "HEAD", "DELETE", "PUT"],
      "AllowedOrigins": ["https://'"${FQDN}"'"],
      "ExposeHeaders": ["etag", "x-amz-server-side-encryption", "x-amz-request-id", "x-amz-id-2"],
      "MaxAgeSeconds": 3000
    }]
  }'
```

---

## 4-7단계: CA 인증서 결합

SQL Server 및/또는 Redis가 사설 CA를 사용한 TLS를 사용하는 경우, 모든 CA 인증서를 단일 파일로 결합합니다:

```bash
# CA 인증서 수집
# - sql-ca.pem: SQL Server CA 인증서
# - redis-ca.pem: Redis CA 인증서
# - registry-ca.pem: 삼성 클라우드 레지스트리 CA (사설인 경우)

# 단일 파일로 결합
cat sql-ca.pem redis-ca.pem > combined-ca.pem

# 결합된 인증서 확인
openssl x509 -in combined-ca.pem -text -noout | head -20

# input.json 경로 확인
echo "input.json의 additional_ca_certs에 사용할 경로: $(pwd)/combined-ca.pem"
```

> **참고:** 공인 CA(예: DigiCert, Let's Encrypt)를 사용하는 경우 시스템 신뢰 저장소에 이미 포함되어 있으므로 이 단계가 불필요할 수 있습니다.

---

## 스토리지 클래스 요약

| 이름 | 프로비저너 | 접근 모드 | 반환 정책 | 용도 |
|------|-----------|-----------|-----------|------|
| `bs-ssd` | `bs.csi.samsungsdscloud.com` | RWO | Delete | 일반 영구 볼륨 |
| `bs-ssd-retain` | `bs.csi.samsungsdscloud.com` | RWO | Retain | 중요 데이터 (데이터베이스) |
| `nfs-subdir-external-sc` | `k8s-sigs.io/nfs-subdir-external-provisioner` | RWX | Delete | StudioWeb, ECS, 공유 스토리지 |
| `nfs-subdir-external-sc-retain` | `k8s-sigs.io/nfs-subdir-external-provisioner` | RWX | Retain | 중요 공유 데이터 |

### input.json의 스토리지 클래스 매핑

```json
{
  "storage_class": "bs-ssd",
  "storage_class_single_replica": "bs-ssd",
  "storage_class_name_with_rwx_support": "nfs-subdir-external-sc"
}
```

---

## 검증 체크리스트

| 확인 항목 | 명령어 | 예상 결과 |
|-----------|--------|-----------|
| 블록 스토리지 CSI | `kubectl get csidrivers` | `bs.csi.samsungsdscloud.com` 표시 |
| bs-ssd StorageClass | `kubectl get sc bs-ssd` | 사용 가능 |
| 테인트 노드 CSI | `kubectl get pods -n kube-system -l app=csi-bs-node -o wide` | 모든 노드에서 Running |
| NFS 프로비저너 실행 | `kubectl get pods -n nfs-system` | Running |
| NFS StorageClass | `kubectl get sc nfs-subdir-external-sc` | 사용 가능 |
| SQL 연결 | Pod에서 TCP 테스트 | 연결 성공 |
| Redis 연결 | Pod에서 PING | PONG 응답 |
| 오브젝트 스토리지 | Pod에서 S3 목록 조회 | 오류 없음 |
| CA 인증서 | `openssl x509 -in combined-ca.pem -text` | 인증서 정보 표시 |

---

## 문제 해결

### PVC가 Pending 상태에 머무르는 경우

```bash
# 이벤트 확인
kubectl describe pvc <pvc-이름>

# 일반적인 원인:
# - StorageClass를 찾을 수 없음 → 이름 일치 확인
# - 노드에서 CSI가 실행되지 않음 → csi-bs-node DaemonSet 확인
# - 디스크 할당량 부족 → 삼성 클라우드 할당량 확인
```

### NFS 마운트 실패

```bash
# NFS 프로비저너 로그 확인
kubectl logs -n nfs-system -l app=nfs-subdir-external-provisioner

# 노드에서 NFS 서버 접근 가능 여부 확인
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- \
  ping -c 3 ${NFS_SERVER}

# 서버의 NFS 익스포트 확인
showmount -e ${NFS_SERVER}
```

### SQL 연결 거부

```bash
# 워커 노드에서 SQL Server로의 방화벽 허용 확인
# SQL Server 포트(1433)에 대한 보안 그룹 규칙 확인

# 여러 노드에서 테스트
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "${node}에서 테스트 중..."
  kubectl debug node/${node} -it --image=busybox -- nc -zv ${SQL_HOST} ${SQL_PORT}
done
```
