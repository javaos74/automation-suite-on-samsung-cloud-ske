#!/bin/bash
# =============================================================================
# UiPath Automation Suite Monitoring Scripts for Samsung Cloud SKE
# =============================================================================
# Usage:
#   ./monitoring-scripts.sh <command> [options]
#
# Commands:
#   health      - Full health check of all components
#   pods        - Pod status overview
#   logs <pod>  - View logs for a specific pod
#   events      - Recent warning events
#   resources   - Node and pod resource usage
#   argocd      - ArgoCD application status
#   storage     - PVC and storage status
#   network     - Network connectivity checks
#   all         - Run all checks
# =============================================================================

NAMESPACE="${UIPATH_NAMESPACE:-uipath}"
FQDN="${UIPATH_FQDN:-ske.myrobots.co.kr}"
ARGOCD_NS="argocd"
ISTIO_NS="istio-system"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo ""
    echo -e "${YELLOW}--- $1 ---${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# Command: health
# =============================================================================
cmd_health() {
    print_header "UiPath Automation Suite Health Check"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Cluster: $(kubectl config current-context)"
    echo "FQDN: ${FQDN}"

    # Node status
    print_section "Node Status"
    TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
    READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready")
    if [ "${TOTAL_NODES}" -eq "${READY_NODES}" ]; then
        print_ok "All nodes ready (${READY_NODES}/${TOTAL_NODES})"
    else
        print_err "Not all nodes ready (${READY_NODES}/${TOTAL_NODES})"
        kubectl get nodes | grep -v " Ready"
    fi

    # Pod status
    print_section "Pod Status (${NAMESPACE})"
    TOTAL_PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers | wc -l)
    RUNNING_PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep -c "Running")
    COMPLETED_PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep -c "Completed")
    FAILED_PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep -cE "CrashLoop|Error|ImagePull|Pending")

    echo "  Total: ${TOTAL_PODS}"
    echo "  Running: ${RUNNING_PODS}"
    echo "  Completed: ${COMPLETED_PODS}"

    if [ "${FAILED_PODS}" -gt 0 ]; then
        print_err "Failed/Pending pods: ${FAILED_PODS}"
        kubectl get pods -n ${NAMESPACE} --no-headers | grep -E "CrashLoop|Error|ImagePull|Pending"
    else
        print_ok "No failed pods"
    fi

    # Istio status
    print_section "Istio Status"
    ISTIOD=$(kubectl get pods -n ${ISTIO_NS} -l app=istiod --no-headers 2>/dev/null | grep -c "Running")
    GATEWAY=$(kubectl get pods -n ${ISTIO_NS} -l app=istio-ingressgateway --no-headers 2>/dev/null | grep -c "Running")
    if [ "${ISTIOD}" -gt 0 ]; then print_ok "istiod running"; else print_err "istiod not running"; fi
    if [ "${GATEWAY}" -gt 0 ]; then print_ok "ingress gateway running"; else print_err "ingress gateway not running"; fi

    # NLB external IP
    EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n ${ISTIO_NS} -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null)
    if [ -n "${EXTERNAL_IP}" ]; then
        print_ok "NLB External IP: ${EXTERNAL_IP}"
    else
        print_err "NLB has no external IP"
    fi

    # ArgoCD status
    print_section "ArgoCD Status"
    ARGOCD_PODS=$(kubectl get pods -n ${ARGOCD_NS} --no-headers 2>/dev/null | grep -c "Running")
    TOTAL_APPS=$(kubectl get applications -n ${ARGOCD_NS} --no-headers 2>/dev/null | wc -l)
    HEALTHY_APPS=$(kubectl get applications -n ${ARGOCD_NS} --no-headers 2>/dev/null | grep -c "Healthy")
    SYNCED_APPS=$(kubectl get applications -n ${ARGOCD_NS} --no-headers 2>/dev/null | grep -c "Synced")

    print_ok "ArgoCD pods running: ${ARGOCD_PODS}"
    echo "  Applications - Total: ${TOTAL_APPS}, Healthy: ${HEALTHY_APPS}, Synced: ${SYNCED_APPS}"

    if [ "${HEALTHY_APPS}" -lt "${TOTAL_APPS}" ]; then
        print_warn "Some applications are not healthy:"
        kubectl get applications -n ${ARGOCD_NS} --no-headers | grep -v "Healthy"
    fi

    # HTTPS check
    print_section "HTTPS Connectivity"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://${FQDN}/ 2>/dev/null)
    if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "302" ]; then
        print_ok "HTTPS accessible (HTTP ${HTTP_CODE})"
    elif [ "${HTTP_CODE}" = "000" ]; then
        print_err "Cannot connect to https://${FQDN}"
    else
        print_warn "HTTPS returned HTTP ${HTTP_CODE}"
    fi

    echo ""
    echo "Health check completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# Command: pods
# =============================================================================
cmd_pods() {
    print_header "Pod Status Overview"

    print_section "UiPath Namespace (${NAMESPACE})"
    kubectl get pods -n ${NAMESPACE} -o wide --sort-by='.status.phase'

    print_section "Istio System"
    kubectl get pods -n ${ISTIO_NS} -o wide

    print_section "ArgoCD"
    kubectl get pods -n ${ARGOCD_NS} -o wide
}

# =============================================================================
# Command: logs
# =============================================================================
cmd_logs() {
    local POD_NAME=$1
    local CONTAINER=$2

    if [ -z "${POD_NAME}" ]; then
        echo "Usage: $0 logs <pod-name> [container-name]"
        echo ""
        echo "Available pods:"
        kubectl get pods -n ${NAMESPACE} --no-headers | awk '{print "  " $1 " (" $3 ")"}'
        return 1
    fi

    print_header "Logs for pod: ${POD_NAME}"

    # Get containers in pod
    CONTAINERS=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

    if [ -z "${CONTAINERS}" ]; then
        print_err "Pod ${POD_NAME} not found in namespace ${NAMESPACE}"
        return 1
    fi

    if [ -n "${CONTAINER}" ]; then
        echo "Container: ${CONTAINER}"
        echo "---"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} -c ${CONTAINER} --tail=100
    else
        for c in ${CONTAINERS}; do
            print_section "Container: ${c}"
            kubectl logs ${POD_NAME} -n ${NAMESPACE} -c ${c} --tail=50
        done
    fi

    # Also show previous logs if pod restarted
    RESTARTS=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    if [ "${RESTARTS}" -gt 0 ]; then
        print_section "Previous logs (pod restarted ${RESTARTS} times)"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} --previous --tail=30 2>/dev/null
    fi
}

# =============================================================================
# Command: events
# =============================================================================
cmd_events() {
    print_header "Recent Events"

    print_section "Warning Events in ${NAMESPACE} (last 30 min)"
    kubectl get events -n ${NAMESPACE} \
        --field-selector type=Warning \
        --sort-by='.lastTimestamp' | tail -30

    print_section "Warning Events in ${ISTIO_NS}"
    kubectl get events -n ${ISTIO_NS} \
        --field-selector type=Warning \
        --sort-by='.lastTimestamp' | tail -10

    print_section "Warning Events in ${ARGOCD_NS}"
    kubectl get events -n ${ARGOCD_NS} \
        --field-selector type=Warning \
        --sort-by='.lastTimestamp' | tail -10
}

# =============================================================================
# Command: resources
# =============================================================================
cmd_resources() {
    print_header "Resource Usage"

    print_section "Node Resources"
    kubectl top nodes 2>/dev/null || echo "Metrics server not available. Install metrics-server for resource monitoring."

    print_section "Top Pods by CPU (${NAMESPACE})"
    kubectl top pods -n ${NAMESPACE} --sort-by=cpu 2>/dev/null | head -15

    print_section "Top Pods by Memory (${NAMESPACE})"
    kubectl top pods -n ${NAMESPACE} --sort-by=memory 2>/dev/null | head -15

    print_section "Node Allocatable vs Requests"
    kubectl describe nodes | grep -A 8 "Allocated resources:" | head -40
}

# =============================================================================
# Command: argocd
# =============================================================================
cmd_argocd() {
    print_header "ArgoCD Application Status"

    kubectl get applications -n ${ARGOCD_NS} \
        -o custom-columns=\
NAME:.metadata.name,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status,\
REVISION:.status.sync.revision

    print_section "Non-Healthy Applications"
    NON_HEALTHY=$(kubectl get applications -n ${ARGOCD_NS} --no-headers | grep -v "Healthy")
    if [ -n "${NON_HEALTHY}" ]; then
        echo "${NON_HEALTHY}"
    else
        print_ok "All applications are healthy"
    fi
}

# =============================================================================
# Command: storage
# =============================================================================
cmd_storage() {
    print_header "Storage Status"

    print_section "PVCs in ${NAMESPACE}"
    kubectl get pvc -n ${NAMESPACE} -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
CAPACITY:.status.capacity.storage,\
STORAGECLASS:.spec.storageClassName,\
ACCESS:.spec.accessModes[0]

    print_section "Pending PVCs"
    PENDING_PVCS=$(kubectl get pvc -n ${NAMESPACE} --no-headers | grep -v "Bound")
    if [ -n "${PENDING_PVCS}" ]; then
        print_warn "Pending PVCs found:"
        echo "${PENDING_PVCS}"
    else
        print_ok "All PVCs are bound"
    fi

    print_section "StorageClasses"
    kubectl get storageclasses
}

# =============================================================================
# Command: network
# =============================================================================
cmd_network() {
    print_header "Network Connectivity Checks"

    print_section "Istio Ingress Gateway Service"
    kubectl get svc istio-ingressgateway -n ${ISTIO_NS} -o wide

    print_section "External HTTPS Check"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://${FQDN}/ 2>/dev/null)
    echo "  https://${FQDN} → HTTP ${HTTP_CODE}"

    HTTP_CODE_ALM=$(curl -sk -o /dev/null -w "%{http_code}" https://alm.${FQDN}/ 2>/dev/null)
    echo "  https://alm.${FQDN} → HTTP ${HTTP_CODE_ALM}"

    print_section "In-Cluster DNS Resolution"
    echo "  Testing FQDN resolution from cluster..."
    kubectl run dns-check --rm -it --image=busybox --restart=Never -- \
        nslookup ${FQDN} 2>/dev/null | grep -A 1 "Address"

    print_section "VirtualServices"
    kubectl get virtualservices -A
}

# =============================================================================
# Command: all
# =============================================================================
cmd_all() {
    cmd_health
    cmd_pods
    cmd_argocd
    cmd_storage
    cmd_resources
    cmd_events
}

# =============================================================================
# Main
# =============================================================================
case "${1}" in
    health)    cmd_health ;;
    pods)      cmd_pods ;;
    logs)      cmd_logs "$2" "$3" ;;
    events)    cmd_events ;;
    resources) cmd_resources ;;
    argocd)    cmd_argocd ;;
    storage)   cmd_storage ;;
    network)   cmd_network ;;
    all)       cmd_all ;;
    *)
        echo "UiPath Automation Suite Monitoring Script"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  health      Full health check of all components"
        echo "  pods        Pod status overview"
        echo "  logs <pod>  View logs for a specific pod (optionally specify container)"
        echo "  events      Recent warning events"
        echo "  resources   Node and pod resource usage"
        echo "  argocd      ArgoCD application status"
        echo "  storage     PVC and storage status"
        echo "  network     Network connectivity checks"
        echo "  all         Run all checks"
        echo ""
        echo "Environment variables:"
        echo "  UIPATH_NAMESPACE  UiPath namespace (default: uipath)"
        echo "  UIPATH_FQDN      Automation Suite FQDN (default: ske.myrobots.co.kr)"
        ;;
esac
