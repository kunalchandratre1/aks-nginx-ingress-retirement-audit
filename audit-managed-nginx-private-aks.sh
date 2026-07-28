#!/usr/bin/env bash
set -euo pipefail

if grep -q $'\r' "$0"; then
  echo "Detected Windows CRLF line endings in this script. Convert and re-run:"
  echo "  sed -i 's/\r$//' $0"
  exit 1
fi

OUTPUT_CSV="managed_nginx_private_aks_audit_$(date +%Y%m%d_%H%M%S).csv"
printf 'subscription_name,subscription_id,resource_group,cluster_name,arm_app_routing_enabled,k8s_api_reachable,k8s_managed_nginx_observed,managed_ingress_namespaces,k8s_oss_nginx_observed,oss_nginx_ingress_namespaces\n' > "$OUTPUT_CSV"

# Required target list format: "<subscription_id>|<resource_group>|<cluster_name>"
TARGETS=(
  # "00000000-0000-0000-0000-000000000000|rg-example|aks-private-example"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|ai-obs-sre-demo|aiosre-aks-demo"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|nb67hg-aksnonginx"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|nb67hg-akspublicnginx"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|nb67hg-akspvtnginx"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|nb67hg-akspvtnginxpriv"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|nb67hg-akspvtnon-nginx"

)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No AKS targets configured. Populate TARGETS and re-run."
  exit 1
fi

TMP_KUBECONFIG="$(mktemp)"
export KUBECONFIG="$TMP_KUBECONFIG"

cleanup() {
  rm -f "$TMP_KUBECONFIG"
}
trap cleanup EXIT

echo "Starting private AKS namespace audit across subscriptions..."

write_row() {
  printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >> "$OUTPUT_CSV"
}

detect_k8s_reachability_issue() {
  local kubectl_output="$1"
  local private_fqdn="$2"

  if echo "$kubectl_output" | grep -qiE 'no such host|server misbehaving|Temporary failure in name resolution'; then
    if [[ -n "$private_fqdn" ]]; then
      echo "PRIVATE_DNS_UNRESOLVABLE:${private_fqdn}"
    else
      echo "PRIVATE_DNS_UNRESOLVABLE"
    fi
    return 0
  fi

  if echo "$kubectl_output" | grep -qiE 'i/o timeout|context deadline exceeded|operation timed out'; then
    echo "PRIVATE_API_TIMEOUT"
    return 0
  fi

  if echo "$kubectl_output" | grep -qiE 'forbidden|unauthorized'; then
    echo "K8S_API_ACCESS_DENIED"
    return 0
  fi

  echo "NOT_IDENTIFIABLE_CLUSTER_PRIVATE_OR_UNREACHABLE"
}

for TARGET in "${TARGETS[@]}"; do
  IFS='|' read -r SUB_ID CLUSTER_RG CLUSTER_NAME <<< "$TARGET"

  GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  if [[ ! "$SUB_ID" =~ $GUID_RE && "$CLUSTER_RG" =~ $GUID_RE ]]; then
    # Auto-correct common accidental order: cluster|subscription|resource_group
    TARGET_CLUSTER_NAME="$SUB_ID"
    SUB_ID="$CLUSTER_RG"
    CLUSTER_RG="$CLUSTER_NAME"
    CLUSTER_NAME="$TARGET_CLUSTER_NAME"
    echo "Auto-corrected target order to subscription|resource_group|cluster_name for: $TARGET"
  fi

  if [[ -z "${SUB_ID:-}" || -z "${CLUSTER_RG:-}" || -z "${CLUSTER_NAME:-}" ]]; then
    echo "Skipping malformed target entry: $TARGET"
    continue
  fi

  SUB_NAME="$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || true)"
  [[ -z "$SUB_NAME" ]] && SUB_NAME="$SUB_ID"

  echo "Processing target: $SUB_NAME ($SUB_ID) / $CLUSTER_RG / $CLUSTER_NAME"

  if ! az account set --subscription "$SUB_ID" >/dev/null 2>&1; then
    write_row "$SUB_NAME" "$SUB_ID" "$CLUSTER_RG" "$CLUSTER_NAME" "unknown" "no" "unknown" "NOT_IDENTIFIABLE_SUBSCRIPTION_ACCESS_ERROR" "unknown" "NOT_IDENTIFIABLE_SUBSCRIPTION_ACCESS_ERROR"
    continue
  fi

  IS_PRIVATE_RAW="$(az aks show --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --query "apiServerAccessProfile.enablePrivateCluster" -o tsv 2>/dev/null || true)"
  if [[ "${IS_PRIVATE_RAW,,}" != "true" ]]; then
    write_row "$SUB_NAME" "$SUB_ID" "$CLUSTER_RG" "$CLUSTER_NAME" "no" "no" "unknown" "SKIPPED_NON_PRIVATE_CLUSTER" "unknown" "SKIPPED_NON_PRIVATE_CLUSTER"
    continue
  fi

    ARM_APP_ROUTING_ENABLED="unknown"
    K8S_API_REACHABLE="unknown"
    K8S_MANAGED_NGINX_OBSERVED="unknown"
    INGRESS_NAMESPACES=""
    K8S_OSS_NGINX_OBSERVED="unknown"
    OSS_INGRESS_NAMESPACES=""

    echo "  Inspecting private AKS: $CLUSTER_NAME (RG: $CLUSTER_RG)"
    : > "$TMP_KUBECONFIG"

    ARM_ENABLED_RAW="$(az aks show --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --query "ingressProfile.webAppRouting.enabled" -o tsv 2>/dev/null || echo "__ARM_QUERY_ERROR__")"
    PRIVATE_FQDN="$(az aks show --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --query "privateFqdn" -o tsv 2>/dev/null || true)"
    case "${ARM_ENABLED_RAW,,}" in
      true) ARM_APP_ROUTING_ENABLED="yes" ;;
      false|""|null) ARM_APP_ROUTING_ENABLED="no" ;;
      __arm_query_error__) ARM_APP_ROUTING_ENABLED="unknown" ;;
      *) ARM_APP_ROUTING_ENABLED="unknown" ;;
    esac

    if ! az aks get-credentials --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --overwrite-existing >/dev/null 2>&1; then
      K8S_API_REACHABLE="no"
      K8S_MANAGED_NGINX_OBSERVED="unknown"
      INGRESS_NAMESPACES="NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED"
      K8S_OSS_NGINX_OBSERVED="unknown"
      OSS_INGRESS_NAMESPACES="NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED"

      write_row "$SUB_NAME" "$SUB_ID" "$CLUSTER_RG" "$CLUSTER_NAME" "$ARM_APP_ROUTING_ENABLED" "$K8S_API_REACHABLE" "$K8S_MANAGED_NGINX_OBSERVED" "$INGRESS_NAMESPACES" "$K8S_OSS_NGINX_OBSERVED" "$OSS_INGRESS_NAMESPACES"
      continue
    fi

    KUBECTL_NS_OUTPUT="$(kubectl get ns --request-timeout=10s 2>&1 || true)"
    if [[ "$KUBECTL_NS_OUTPUT" == *"Unable to connect to the server"* || "$KUBECTL_NS_OUTPUT" == *"couldn't get current server API group list"* || "$KUBECTL_NS_OUTPUT" == *"Error from server"* ]]; then
      K8S_API_REACHABLE="no"
      K8S_MANAGED_NGINX_OBSERVED="unknown"
      INGRESS_NAMESPACES="$(detect_k8s_reachability_issue "$KUBECTL_NS_OUTPUT" "$PRIVATE_FQDN")"
      K8S_OSS_NGINX_OBSERVED="unknown"
      OSS_INGRESS_NAMESPACES="$INGRESS_NAMESPACES"

      write_row "$SUB_NAME" "$SUB_ID" "$CLUSTER_RG" "$CLUSTER_NAME" "$ARM_APP_ROUTING_ENABLED" "$K8S_API_REACHABLE" "$K8S_MANAGED_NGINX_OBSERVED" "$INGRESS_NAMESPACES" "$K8S_OSS_NGINX_OBSERVED" "$OSS_INGRESS_NAMESPACES"
      continue
    fi

    K8S_API_REACHABLE="yes"
    INGRESS_LINES="$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.spec.ingressClassName}{"|"}{.metadata.annotations.kubernetes\.io/ingress\.class}{"\n"}{end}' 2>/dev/null || true)"

    if kubectl get nginxingresscontroller.approuting.kubernetes.azure.com >/dev/null 2>&1; then
      MANAGED_CLASSES="$(kubectl get nginxingresscontroller.approuting.kubernetes.azure.com -o jsonpath='{range .items[*]}{.spec.ingressClassName}{"\n"}{end}' 2>/dev/null || true)"

      if [[ -n "$MANAGED_CLASSES" ]]; then
        K8S_MANAGED_NGINX_OBSERVED="yes"

        if [[ -n "$INGRESS_LINES" ]]; then
          INGRESS_NAMESPACES="$({
            while IFS='|' read -r NS SPEC_CLASS ANN_CLASS; do
              [[ -z "${NS:-}" ]] && continue
              for C in $MANAGED_CLASSES; do
                if [[ "${SPEC_CLASS:-}" == "$C" || "${ANN_CLASS:-}" == "$C" ]]; then
                  echo "$NS"
                  break
                fi
              done
            done <<< "$INGRESS_LINES"
          } | sort -u | paste -sd ';' -)"
        fi

        [[ -z "$INGRESS_NAMESPACES" ]] && INGRESS_NAMESPACES="NONE_USING_MANAGED_CLASS"
      else
        K8S_MANAGED_NGINX_OBSERVED="no"
        INGRESS_NAMESPACES="N/A"
      fi
    else
      K8S_MANAGED_NGINX_OBSERVED="no"
      INGRESS_NAMESPACES="N/A"
    fi

    OSS_CLASSES="$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.controller}{"\n"}{end}' 2>/dev/null | awk -F'|' '$2=="k8s.io/ingress-nginx"{print $1}' || true)"
    OSS_CONTROLLER_PRESENT="no"
    if kubectl get deploy -A -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep -q .; then
      OSS_CONTROLLER_PRESENT="yes"
    elif kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep -q .; then
      OSS_CONTROLLER_PRESENT="yes"
    fi

    if [[ -n "$OSS_CLASSES" || "$OSS_CONTROLLER_PRESENT" == "yes" ]]; then
      K8S_OSS_NGINX_OBSERVED="yes"

      if [[ -n "$INGRESS_LINES" && -n "$OSS_CLASSES" ]]; then
        OSS_INGRESS_NAMESPACES="$({
          while IFS='|' read -r NS SPEC_CLASS ANN_CLASS; do
            [[ -z "${NS:-}" ]] && continue
            for C in $OSS_CLASSES; do
              if [[ "${SPEC_CLASS:-}" == "$C" || "${ANN_CLASS:-}" == "$C" ]]; then
                echo "$NS"
                break
              fi
            done
          done <<< "$INGRESS_LINES"
        } | sort -u | paste -sd ';' -)"
      fi

      if [[ -z "$OSS_INGRESS_NAMESPACES" ]]; then
        OSS_INGRESS_NAMESPACES="NONE_USING_OSS_CLASS"
      fi
    else
      K8S_OSS_NGINX_OBSERVED="no"
      OSS_INGRESS_NAMESPACES="N/A"
    fi

    write_row "$SUB_NAME" "$SUB_ID" "$CLUSTER_RG" "$CLUSTER_NAME" "$ARM_APP_ROUTING_ENABLED" "$K8S_API_REACHABLE" "$K8S_MANAGED_NGINX_OBSERVED" "$INGRESS_NAMESPACES" "$K8S_OSS_NGINX_OBSERVED" "$OSS_INGRESS_NAMESPACES"

done

echo "Private AKS audit completed. CSV file: $OUTPUT_CSV"
echo ""
echo "========== BEGIN AUDIT CSV =========="
cat "$OUTPUT_CSV"
echo "=========== END AUDIT CSV ==========="

if command -v column >/dev/null 2>&1; then
  echo ""
  echo "Formatted preview:"
  column -s, -t "$OUTPUT_CSV" | head -n 50
fi
