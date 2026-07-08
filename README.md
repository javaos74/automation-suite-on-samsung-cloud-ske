# UiPath Automation Suite on Samsung Cloud SKE

Deployment manual for UiPath Automation Suite on Samsung Cloud SKE (Samsung Kubernetes Engine) in an airgapped environment.

삼성 클라우드 SKE(Samsung Kubernetes Engine)에 에어갭 환경으로 UiPath Automation Suite을 배포하기 위한 단계별 매뉴얼입니다.

---

## Overview / 개요

This repository provides a step-by-step guide for deploying UiPath Automation Suite 2.2510 on Samsung Cloud SKE. The guide is designed for airgapped (offline) environments where all container images and Helm charts are served from a private registry.

이 리포지토리는 삼성 클라우드 SKE에 UiPath Automation Suite 2.2510을 배포하기 위한 단계별 가이드를 제공합니다. 모든 컨테이너 이미지와 Helm 차트를 프라이빗 레지스트리에서 제공하는 에어갭(오프라인) 환경을 기준으로 작성되었습니다.

## Target Environment / 대상 환경

| Item / 항목 | Value / 값 |
|-------------|------------|
| Platform | Samsung Cloud SKE |
| UiPath Version | 2.2510.2 |
| Kubernetes | v1.34.x |
| Istio | 1.30.x (Helm) |
| ArgoCD | v3.4.4 (Helm chart 10.1.1) |
| OS | RHEL 9.4 |
| Container Runtime | containerd 1.7.x |
| CNI | Calico |

## Documents / 문서

| # | English (en/) | Korean (ko/) |
|---|---------------|--------------|
| 1 | [Offline Registry & Airgap Preparation](en/01-offline-registry-airgap.md) | [오프라인 레지스트리 및 에어갭 준비](ko/01-offline-registry-airgap.md) |
| 2 | [SKE Cluster & Node Pool Configuration](en/02-ske-cluster-nodepool.md) | [SKE 클러스터 및 노드 풀 구성](ko/02-ske-cluster-nodepool.md) |
| 3 | [Network, NLB & Firewall Configuration](en/03-network-nlb-firewall.md) | [네트워크, NLB 및 방화벽 구성](ko/03-network-nlb-firewall.md) |
| 4 | [Storage & External Dependencies](en/04-storage-external-deps.md) | [스토리지 및 외부 의존성 구성](ko/04-storage-external-deps.md) |
| 5 | [Istio Installation + NLB Integration](en/05-istio-install.md) | [Istio 설치 + NLB 연동](ko/05-istio-install.md) |
| 6 | [ArgoCD Installation + NLB Sharing](en/06-argocd-install.md) | [ArgoCD 설치 + NLB 공유](ko/06-argocd-install.md) |
| 7 | [UiPath Automation Suite Installation](en/07-install-automation-suite.md) | [UiPath Automation Suite 설치](ko/07-install-automation-suite.md) |
| 8 | [Verification & Monitoring](en/08-verification-monitoring.md) | [검증 및 모니터링](ko/08-verification-monitoring.md) |

## YAML / Config Files / 설정 파일

| File / 파일 | Purpose / 용도 |
|-------------|----------------|
| `istio-ingressgateway-nlb.yaml` | Istio gateway Service with Samsung NLB annotations / 삼성 NLB 어노테이션이 포함된 Istio 게이트웨이 서비스 |
| `argocd-virtualservice.yaml` | ArgoCD VirtualService sharing NLB / NLB를 공유하는 ArgoCD VirtualService |
| `argocd-appproject.yaml` | UiPath AppProject definition / UiPath AppProject 정의 |
| `argocd-values.yaml` | ArgoCD Helm values for airgap / 에어갭용 ArgoCD Helm 값 |
| `gpu-mig-configmap.yaml` | NVIDIA MIG partition config / NVIDIA MIG 파티션 설정 |
| `nvidia-mig-manager.yaml` | MIG Manager DaemonSet / MIG Manager DaemonSet |
| `csi-bs-node-toleration-patch.yaml` | CSI DaemonSet toleration patch / CSI DaemonSet toleration 패치 |
| `nfs-provisioner-values.yaml` | NFS Helm chart values / NFS Helm 차트 값 |
| `coredns-custom-config.yaml` | CoreDNS custom forwarding / CoreDNS 커스텀 포워딩 |
| `resource-quotas.yaml` | Namespace ResourceQuotas / 네임스페이스 ResourceQuota |
| `input-ske.json` | input.json template for SKE / SKE용 input.json 템플릿 |
| `monitoring-scripts.sh` | Health check & log collection script / 헬스 체크 및 로그 수집 스크립트 |

## Node Pool Architecture / 노드 풀 아키텍처

| Pool / 풀 | Spec / 사양 | Count / 수량 | Purpose / 용도 |
|-----------|-------------|-------------|----------------|
| General Workers | 32 vCPU, 96G RAM | 5+ | UiPath platform services / UiPath 플랫폼 서비스 |
| ASRobot Workers | 32 vCPU, 64G RAM | 1+ | Automation Suite Robots / Automation Suite 로봇 |
| GPU Workers | 32 vCPU, 128G RAM, A100-80G | 1 | AI Center GPU workloads / AI Center GPU 워크로드 |

## Prerequisites / 사전 요구 사항

- Dedicated SKE cluster with Cluster Admin privileges / Cluster Admin 권한이 있는 전용 SKE 클러스터
- SQL Server 2019/2022 accessible from cluster / 클러스터에서 접근 가능한 SQL Server 2019/2022
- Redis 6.x/7.x with TLS enabled / TLS가 활성화된 Redis 6.x/7.x
- S3-compatible Object Storage / S3 호환 오브젝트 스토리지
- NFS Server for RWX storage / RWX 스토리지를 위한 NFS 서버
- Private container registry (Samsung Cloud Registry) / 프라이빗 컨테이너 레지스트리 (삼성 클라우드 레지스트리)

## References / 참고 자료

- [UiPath Automation Suite Installation Guide (EKS/AKS)](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/)
- [UiPath OCI Registry Configuration](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-eks-aks/configuring-the-oci-compliant-registry)
- [Samsung Cloud SKE LoadBalancer](https://docs.e.samsungsdscloud.com/userguide/container/k8s_engine/usage_guide/k8s_typelb_use/)
- [UiPath Compatibility Matrix](https://docs.uipath.com/automation-suite/automation-suite/2.2510/installation-guide-openshift/compatibility-matrix)
- [UiPath Sizing Calculator](https://docs.uipath.com/automation-suite/2025.10/calculator)

---

## License / 라이선스

This documentation is provided as-is for internal deployment reference purposes.

이 문서는 내부 배포 참고용으로 제공됩니다.
