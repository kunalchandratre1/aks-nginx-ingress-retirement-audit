#!/usr/bin/env bash
set -euo pipefail

if grep -q $'\r' "$0"; then
  echo "Detected Windows CRLF line endings in this script. Convert and re-run:"
  echo "  sed -i 's/\r$//' $0"
  exit 1
fi

# Required target list format: "<subscription_id>|<resource_group>|<cluster_name>"
TARGETS=(
  # "00000000-0000-0000-0000-000000000000|rg-example|aks-example"
)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No AKS targets configured. Populate TARGETS and re-run."
  exit 1
fi

REPORT_FILE="oss_nginx_investigation_$(date +%Y%m%d_%H%M%S).txt"
TMP_KUBECONFIG="$(mktemp)"
export KUBECONFIG="$TMP_KUBECONFIG"

cleanup() {
  rm -f "$TMP_KUBECONFIG"
}
trap cleanup EXIT

log() {
  echo "$*" | tee -a "$REPORT_FILE"
}

section() {
  log ""
  log "============================================================"
  log "$*"
  log "============================================================"
}

run_cmd() {
  local description="$1"
  shift

  log ""
  log ">>> $description"
  log ">>> Command: $*"

  if "$@" 2>&1 | tee -a "$REPORT_FILE"; then
    return 0
  fi

  log "[command failed]"
  return 1
}

collect_ingress_lines() {
  kubectl get ingress -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.ingressClassName}{"|"}{.metadata.annotations.kubernetes\.io/ingress\.class}{"|"}{range .spec.rules[*]}{.host}{","}{end}{"\n"}{end}' \
    2>/dev/null || true
}

for TARGET in "${TARGETS[@]}"; do
  IFS='|' read -r SUB_ID CLUSTER_RG CLUSTER_NAME <<< "$TARGET"

  if [[ -z "${SUB_ID:-}" || -z "${CLUSTER_RG:-}" || -z "${CLUSTER_NAME:-}" ]]; then
    log "Skipping malformed target entry: $TARGET"
    continue
  fi

  SUB_NAME="$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || true)"
  [[ -z "$SUB_NAME" ]] && SUB_NAME="$SUB_ID"

  section "Investigating OSS ingress-nginx usage: $SUB_NAME / $CLUSTER_RG / $CLUSTER_NAME"

  if ! az account set --subscription "$SUB_ID" >/dev/null 2>&1; then
    log "Unable to switch to subscription: $SUB_ID"
    continue
  fi

  : > "$TMP_KUBECONFIG"

  if ! run_cmd "Fetch cluster credentials" az aks get-credentials --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --overwrite-existing; then
    log "Cannot investigate further because credentials could not be fetched."
    continue
  fi

  if ! run_cmd "Verify Kubernetes API access" kubectl get ns --request-timeout=10s; then
    log "Cannot investigate further because Kubernetes API is not reachable from this execution environment."
    continue
  fi

  run_cmd "Cluster exposure details" az aks show --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --query '{private:apiServerAccessProfile.enablePrivateCluster,fqdn:fqdn,privateFqdn:privateFqdn}' -o json

  run_cmd "Ingress classes" kubectl get ingressclass
  run_cmd "Ingress classes with controller and default flag" kubectl get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class

  INGRESS_LINES="$(collect_ingress_lines)"
  section "Ingress inventory"
  log "namespace|name|spec.ingressClassName|annotation kubernetes.io/ingress.class|hosts"
  if [[ -n "$INGRESS_LINES" ]]; then
    printf '%s\n' "$INGRESS_LINES" | tee -a "$REPORT_FILE"
  else
    log "No ingress resources found."
  fi

  section "Classless ingress resources"
  if [[ -n "$INGRESS_LINES" ]]; then
    printf '%s\n' "$INGRESS_LINES" | awk -F'|' '$3=="" && $4=="" {print}' | tee -a "$REPORT_FILE"
  else
    log "No ingress resources found."
  fi

  OSS_CLASSES="$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.controller}{"\n"}{end}' 2>/dev/null | awk -F'|' '$2=="k8s.io/ingress-nginx"{print $1}' || true)"

  section "Ingress resources explicitly using OSS ingress-nginx classes"
  if [[ -n "$INGRESS_LINES" && -n "$OSS_CLASSES" ]]; then
    while IFS= read -r oss_class; do
      [[ -z "$oss_class" ]] && continue
      log "-- ingress class: $oss_class"
      printf '%s\n' "$INGRESS_LINES" | awk -F'|' -v klass="$oss_class" '$3==klass || $4==klass {print}' | tee -a "$REPORT_FILE"
    done <<< "$OSS_CLASSES"
  else
    log "No OSS ingress-nginx ingress classes were found."
  fi

  run_cmd "ingress-nginx controller workloads (deployments/daemonsets/statefulsets)" kubectl get deploy,ds,sts -A -l app.kubernetes.io/name=ingress-nginx -o wide
  run_cmd "ingress-nginx controller pods" kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx -o wide
  run_cmd "ingress-nginx services" kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx -o wide

  section "Potential ingress-nginx related ConfigMaps and Secrets"
  kubectl get configmap -A --no-headers 2>/dev/null | grep -Ei 'ingress-nginx|nginx-ingress' | tee -a "$REPORT_FILE" || log "No matching ConfigMaps found."
  kubectl get secret -A --no-headers 2>/dev/null | grep -Ei 'ingress-nginx|nginx-ingress' | tee -a "$REPORT_FILE" || log "No matching Secrets found."

  if command -v helm >/dev/null 2>&1; then
    section "Helm releases related to ingress-nginx"
    helm list -A 2>/dev/null | grep -Ei 'ingress-nginx|nginx-ingress' | tee -a "$REPORT_FILE" || log "No matching Helm releases found."
  fi

  section "Decision hints"
  log "1. If OSS controller workloads exist and no ingress uses OSS class, check whether a default ingress class exists."
  log "2. If classless ingress resources exist, they may still be routed through a default ingress class."
  log "3. If workloads and services exist but no ingress uses them, investigate non-Ingress usage such as TCP/UDP or leftover installs."
  log "4. If no controller workloads, no services, and no ingress classes remain, it is likely a cleanup/removal candidate."
done

log ""
log "Investigation completed. Report file: $REPORT_FILE"