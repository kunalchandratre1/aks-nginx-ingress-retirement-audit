#!/usr/bin/env bash
set -euo pipefail

if grep -q $'\r' "$0"; then
  echo "Detected Windows CRLF line endings in this script. Convert and re-run:"
  echo "  sed -i 's/\r$//' $0"
  exit 1
fi

RESOURCE_GROUP="rg-aks-ingress-compare-aue"
NAME_PREFIX=""
NAMESPACE="sample-api"

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --resource-group <name>   AKS resource group (default: ${RESOURCE_GROUP})
  --name-prefix <value>     Optional prefix used in Bicep cluster names
  --namespace <name>        Namespace for API workloads (default: ${NAMESPACE})
  -h, --help                Show this help

Example:
  $0 --resource-group rg-aks-ingress-compare-aue --name-prefix nb67hg
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      RESOURCE_GROUP="$2"; shift 2 ;;
    --name-prefix)
      NAME_PREFIX="$2"; shift 2 ;;
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI not found." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required_file in api1.py api2.py api3.py api-router.py; do
  if [[ ! -f "${SCRIPT_DIR}/${required_file}" ]]; then
    echo "Missing required file: ${required_file} in ${SCRIPT_DIR}" >&2
    exit 1
  fi
done

normalize_prefix() {
  local raw="$1"
  raw="${raw,,}"
  raw="${raw%-}"
  echo "$raw"
}

NAME_PREFIX="$(normalize_prefix "$NAME_PREFIX")"
if [[ -n "$NAME_PREFIX" ]]; then
  PREFIX="${NAME_PREFIX}-"
else
  PREFIX=""
fi

CLUSTER_PUBLIC_MANAGED="${PREFIX}akspublicnginx"
CLUSTER_PRIVATE_MANAGED_ON_PUBLIC="${PREFIX}akspvtnginx"
CLUSTER_PUBLIC_NO_NGINX="${PREFIX}aksnonginx"
CLUSTER_PRIVATE_MANAGED="${PREFIX}akspvtnginxpriv"
CLUSTER_PRIVATE_NO_NGINX="${PREFIX}akspvtnon-nginx"

echo "Starting post-deploy workload rollout"
echo "Resource group: ${RESOURCE_GROUP}"
echo "Namespace: ${NAMESPACE}"
echo "Cluster prefix: ${PREFIX:-<none>}"

deploy_api_base() {
  local cluster_name="$1"

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$NAMESPACE" create configmap api1-code --from-file=api1.py="${SCRIPT_DIR}/api1.py" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" create configmap api2-code --from-file=api2.py="${SCRIPT_DIR}/api2.py" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" create configmap api3-code --from-file=api3.py="${SCRIPT_DIR}/api3.py" --dry-run=client -o yaml | kubectl apply -f -

  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api1
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api1
  template:
    metadata:
      labels:
        app: api1
    spec:
      nodeSelector:
        kubernetes.azure.com/agentpool: userpool
      containers:
      - name: api1
        image: python:3.11-alpine
        command: ["python", "/app/api1.py"]
        env:
        - name: CLUSTER_NAME
          value: ${cluster_name}
        - name: ENDPOINT_NAME
          value: api1
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: code
          mountPath: /app/api1.py
          subPath: api1.py
      volumes:
      - name: code
        configMap:
          name: api1-code
---
apiVersion: v1
kind: Service
metadata:
  name: api1
  namespace: ${NAMESPACE}
spec:
  selector:
    app: api1
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api2
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api2
  template:
    metadata:
      labels:
        app: api2
    spec:
      nodeSelector:
        kubernetes.azure.com/agentpool: userpool
      containers:
      - name: api2
        image: python:3.11-alpine
        command: ["python", "/app/api2.py"]
        env:
        - name: CLUSTER_NAME
          value: ${cluster_name}
        - name: ENDPOINT_NAME
          value: api2
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: code
          mountPath: /app/api2.py
          subPath: api2.py
      volumes:
      - name: code
        configMap:
          name: api2-code
---
apiVersion: v1
kind: Service
metadata:
  name: api2
  namespace: ${NAMESPACE}
spec:
  selector:
    app: api2
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api3
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api3
  template:
    metadata:
      labels:
        app: api3
    spec:
      nodeSelector:
        kubernetes.azure.com/agentpool: userpool
      containers:
      - name: api3
        image: python:3.11-alpine
        command: ["python", "/app/api3.py"]
        env:
        - name: CLUSTER_NAME
          value: ${cluster_name}
        - name: ENDPOINT_NAME
          value: api3
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: code
          mountPath: /app/api3.py
          subPath: api3.py
      volumes:
      - name: code
        configMap:
          name: api3-code
---
apiVersion: v1
kind: Service
metadata:
  name: api3
  namespace: ${NAMESPACE}
spec:
  selector:
    app: api3
  ports:
  - port: 80
    targetPort: 8080
YAML
}

deploy_managed_ingress() {
  local ingress_class="$1"

  cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sample-api-ingress
  namespace: ${NAMESPACE}
spec:
  ingressClassName: ${ingress_class}
  rules:
  - host: myapp
    http:
      paths:
      - path: /api1
        pathType: Prefix
        backend:
          service:
            name: api1
            port:
              number: 80
      - path: /api2
        pathType: Prefix
        backend:
          service:
            name: api2
            port:
              number: 80
      - path: /api3
        pathType: Prefix
        backend:
          service:
            name: api3
            port:
              number: 80
YAML
}

enable_internal_managed_nginx() {
  if ! kubectl get crd nginxingresscontrollers.approuting.kubernetes.azure.com >/dev/null 2>&1; then
    echo "    Managed NGINX CRD not ready yet; skipping internal NGINX config in this run. Re-run script after add-on is ready."
    return 0
  fi

  cat <<YAML | kubectl apply -f -
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: default
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
  controllerNamePrefix: nginx
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
YAML
}

deploy_router_service() {
  kubectl -n "$NAMESPACE" create configmap api-router-code --from-file=api-router.py="${SCRIPT_DIR}/api-router.py" --dry-run=client -o yaml | kubectl apply -f -

  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-router
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-router
  template:
    metadata:
      labels:
        app: api-router
    spec:
      nodeSelector:
        kubernetes.azure.com/agentpool: userpool
      containers:
      - name: api-router
        image: python:3.11-alpine
        command: ["python", "/app/api-router.py"]
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: code
          mountPath: /app/api-router.py
          subPath: api-router.py
      volumes:
      - name: code
        configMap:
          name: api-router-code
---
apiVersion: v1
kind: Service
metadata:
  name: sample-api-public
  namespace: ${NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: api-router
  ports:
  - port: 80
    targetPort: 8080
YAML
}

configure_cluster() {
  local cluster_name="$1"
  local profile="$2"

  echo ""
  echo "=== Configuring cluster: ${cluster_name} (${profile}) ==="

  if ! az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$cluster_name" --overwrite-existing >/dev/null 2>&1; then
    echo "  Unable to fetch credentials for ${cluster_name}. Skipping."
    return 0
  fi

  if ! kubectl get ns --request-timeout=10s >/dev/null 2>&1; then
    echo "  Kubernetes API not reachable for ${cluster_name} from current network. Skipping."
    return 0
  fi

  deploy_api_base "$cluster_name"

  case "$profile" in
    managed-public)
      deploy_managed_ingress "webapprouting.kubernetes.azure.com"
      ;;
    managed-internal)
      deploy_managed_ingress "webapprouting.kubernetes.azure.com"
      enable_internal_managed_nginx
      ;;
    no-nginx-public)
      deploy_router_service
      ;;
    private-no-nginx)
      echo "    No ingress/router for this profile by design."
      ;;
  esac

  echo "  Completed cluster: ${cluster_name}"
}

configure_cluster "$CLUSTER_PUBLIC_MANAGED" "managed-public"
configure_cluster "$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC" "managed-internal"
configure_cluster "$CLUSTER_PUBLIC_NO_NGINX" "no-nginx-public"
configure_cluster "$CLUSTER_PRIVATE_MANAGED" "managed-internal"
configure_cluster "$CLUSTER_PRIVATE_NO_NGINX" "private-no-nginx"

echo ""
echo "Post-deploy workload rollout completed."
echo "If any cluster was skipped due to reachability, run this script again from a network path that can access that cluster API."
