targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('AKS Kubernetes version. Leave empty to use Azure default.')
param kubernetesVersion string = ''

@description('VM size for both system and user pools.')
param nodeVmSize string = 'Standard_B2s'

@description('Node count for system and user pools.')
@minValue(1)
param nodeCount int = 1

@description('Optional prefix to avoid name collisions in shared subscriptions.')
param namePrefix string = ''

@description('Cleanup deployment script resources after success.')
@allowed([
  'Always'
  'OnSuccess'
  'OnExpiration'
])
param cleanupPreference string = 'OnSuccess'

var normalizedPrefix = empty(namePrefix) ? '' : '${toLower(namePrefix)}-'
var clusters = {
  publicManaged: '${normalizedPrefix}akspublicnginx'
  privateManagedOnPublic: '${normalizedPrefix}akspvtnginx'
  publicNoNginx: '${normalizedPrefix}aksnonginx'
  privateManaged: '${normalizedPrefix}akspvtnginxpriv'
  privateNoNginx: '${normalizedPrefix}akspvtnon-nginx'
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${normalizedPrefix}id-aks-demo-deployer'
  location: location
}

resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, 'aks-demo-contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployDemo 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${normalizedPrefix}deploy-aks-ingress-comparison'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.61.0'
    timeout: 'PT6H'
    retentionInterval: 'P1D'
    cleanupPreference: cleanupPreference
    environmentVariables: [
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        name: 'LOCATION'
        value: location
      }
      {
        name: 'K8S_VERSION'
        value: kubernetesVersion
      }
      {
        name: 'NODE_VM_SIZE'
        value: nodeVmSize
      }
      {
        name: 'NODE_COUNT'
        value: string(nodeCount)
      }
      {
        name: 'CLUSTER_PUBLIC_MANAGED'
        value: clusters.publicManaged
      }
      {
        name: 'CLUSTER_PRIVATE_MANAGED_ON_PUBLIC'
        value: clusters.privateManagedOnPublic
      }
      {
        name: 'CLUSTER_PUBLIC_NO_NGINX'
        value: clusters.publicNoNginx
      }
      {
        name: 'CLUSTER_PRIVATE_MANAGED'
        value: clusters.privateManaged
      }
      {
        name: 'CLUSTER_PRIVATE_NO_NGINX'
        value: clusters.privateNoNginx
      }
    ]
    scriptContent: '''
#!/usr/bin/env bash
set -euo pipefail

RG="$RESOURCE_GROUP"
LOC="$LOCATION"
K8S_VERSION="$K8S_VERSION"
NODE_VM_SIZE="$NODE_VM_SIZE"
NODE_COUNT="$NODE_COUNT"

CLUSTER_PUBLIC_MANAGED="$CLUSTER_PUBLIC_MANAGED"
CLUSTER_PRIVATE_MANAGED_ON_PUBLIC="$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC"
CLUSTER_PUBLIC_NO_NGINX="$CLUSTER_PUBLIC_NO_NGINX"
CLUSTER_PRIVATE_MANAGED="$CLUSTER_PRIVATE_MANAGED"
CLUSTER_PRIVATE_NO_NGINX="$CLUSTER_PRIVATE_NO_NGINX"

echo "Starting AKS demo deployment in resource group: $RG"

echo "Ensuring AKS preview extension and defaults..."
az extension add --name aks-preview --upgrade >/dev/null 2>&1 || true

create_cluster() {
  local cluster_name="$1"
  local private_cluster="$2"
  local app_routing="$3"

  echo "\n=== Creating cluster: $cluster_name (private=$private_cluster, appRouting=$app_routing) ==="

  local cmd=(az aks create
    --resource-group "$RG"
    --name "$cluster_name"
    --location "$LOC"
    --node-count "$NODE_COUNT"
    --node-vm-size "$NODE_VM_SIZE"
    --enable-managed-identity
    --network-plugin azure
    --generate-ssh-keys
    --yes)

  if [ -n "$K8S_VERSION" ]; then
    cmd+=(--kubernetes-version "$K8S_VERSION")
  fi

  if [ "$private_cluster" = "true" ]; then
    cmd+=(--enable-private-cluster)
  fi

  if [ "$app_routing" = "true" ]; then
    cmd+=(--enable-app-routing)
  fi

  "${cmd[@]}"

  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$cluster_name" \
    --name userpool \
    --mode User \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_VM_SIZE" \
    --os-type Linux \
    --yes
}

run_in_cluster() {
  local cluster_name="$1"
  local inline_script="$2"

  az aks command invoke \
    --resource-group "$RG" \
    --name "$cluster_name" \
    --command "$inline_script" \
    --only-show-errors >/dev/null
}

deploy_api_workloads() {
  local cluster_name="$1"

  local cmd='set -e
kubectl create namespace sample-api --dry-run=client -o yaml | kubectl apply -f -

cat <<"PY" >/tmp/api1.py
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown-cluster")
ENDPOINT_NAME = os.getenv("ENDPOINT_NAME", "api1")
HOSTNAME = socket.gethostname()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "endpoint": ENDPOINT_NAME,
            "cluster": CLUSTER_NAME,
            "pathReceived": self.path,
            "timestampUtc": datetime.now(timezone.utc).isoformat(),
            "podHostname": HOSTNAME,
        }
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

cat <<"PY" >/tmp/api2.py
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown-cluster")
ENDPOINT_NAME = os.getenv("ENDPOINT_NAME", "api2")
HOSTNAME = socket.gethostname()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "endpoint": ENDPOINT_NAME,
            "cluster": CLUSTER_NAME,
            "pathReceived": self.path,
            "timestampUtc": datetime.now(timezone.utc).isoformat(),
            "podHostname": HOSTNAME,
        }
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

cat <<"PY" >/tmp/api3.py
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown-cluster")
ENDPOINT_NAME = os.getenv("ENDPOINT_NAME", "api3")
HOSTNAME = socket.gethostname()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "endpoint": ENDPOINT_NAME,
            "cluster": CLUSTER_NAME,
            "pathReceived": self.path,
            "timestampUtc": datetime.now(timezone.utc).isoformat(),
            "podHostname": HOSTNAME,
        }
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

kubectl -n sample-api create configmap api1-code --from-file=api1.py=/tmp/api1.py --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sample-api create configmap api2-code --from-file=api2.py=/tmp/api2.py --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sample-api create configmap api3-code --from-file=api3.py=/tmp/api3.py --dry-run=client -o yaml | kubectl apply -f -

cat <<"YAML" >/tmp/sample-api-base.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api1
  namespace: sample-api
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
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
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
  namespace: sample-api
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
  namespace: sample-api
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
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
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
  namespace: sample-api
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
  namespace: sample-api
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
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
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
  namespace: sample-api
spec:
  selector:
    app: api3
  ports:
  - port: 80
    targetPort: 8080
YAML

kubectl apply -f /tmp/sample-api-base.yaml'

  run_in_cluster "$cluster_name" "$cmd"
}

deploy_managed_ingress() {
  local cluster_name="$1"

  local cmd='set -e
cat <<"YAML" >/tmp/managed-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sample-api-ingress
  namespace: sample-api
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
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
kubectl apply -f /tmp/managed-ingress.yaml'

  run_in_cluster "$cluster_name" "$cmd"
}

enable_internal_managed_nginx() {
  local cluster_name="$1"

  local cmd='set -e
cat <<"YAML" >/tmp/internal-nginx.yaml
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
kubectl apply -f /tmp/internal-nginx.yaml'

  run_in_cluster "$cluster_name" "$cmd"
}

deploy_router_service() {
  local cluster_name="$1"

  local cmd='set -e
cat <<"PY" >/tmp/api-router.py
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        target = None
        if self.path.startswith("/api1"):
            target = "http://api1.sample-api.svc.cluster.local:80"
        elif self.path.startswith("/api2"):
            target = "http://api2.sample-api.svc.cluster.local:80"
        elif self.path.startswith("/api3"):
            target = "http://api3.sample-api.svc.cluster.local:80"

        if target is None:
            body = b"{\"error\":\"not-found\",\"allowedEndpoints\":[\"/api1\",\"/api2\",\"/api3\"]}"
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        try:
            with urllib.request.urlopen(target, timeout=5) as response:
                body = response.read()
                status = response.getcode()
                content_type = response.headers.get("Content-Type", "application/json")
        except urllib.error.URLError:
            body = b"{\"error\":\"backend-unreachable\"}"
            status = 502
            content_type = "application/json"

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

kubectl -n sample-api create configmap api-router-code --from-file=api-router.py=/tmp/api-router.py --dry-run=client -o yaml | kubectl apply -f -

cat <<"YAML" >/tmp/router.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-router
  namespace: sample-api
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
  namespace: sample-api
spec:
  type: LoadBalancer
  selector:
    app: api-router
  ports:
  - port: 80
    targetPort: 8080
YAML

kubectl apply -f /tmp/router.yaml'

  run_in_cluster "$cluster_name" "$cmd"
}

create_cluster "$CLUSTER_PUBLIC_MANAGED" false true
create_cluster "$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC" false true
create_cluster "$CLUSTER_PUBLIC_NO_NGINX" false false
create_cluster "$CLUSTER_PRIVATE_MANAGED" true true
create_cluster "$CLUSTER_PRIVATE_NO_NGINX" true false

deploy_api_workloads "$CLUSTER_PUBLIC_MANAGED"
deploy_api_workloads "$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC"
deploy_api_workloads "$CLUSTER_PUBLIC_NO_NGINX"
deploy_api_workloads "$CLUSTER_PRIVATE_MANAGED"
deploy_api_workloads "$CLUSTER_PRIVATE_NO_NGINX"

deploy_managed_ingress "$CLUSTER_PUBLIC_MANAGED"
deploy_managed_ingress "$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC"
deploy_managed_ingress "$CLUSTER_PRIVATE_MANAGED"

enable_internal_managed_nginx "$CLUSTER_PRIVATE_MANAGED_ON_PUBLIC"
enable_internal_managed_nginx "$CLUSTER_PRIVATE_MANAGED"

deploy_router_service "$CLUSTER_PUBLIC_NO_NGINX"

echo "\nDeployment complete. Clusters created and workloads deployed."
echo "AKS clusters:"
echo " - $CLUSTER_PUBLIC_MANAGED"
echo " - $CLUSTER_PRIVATE_MANAGED_ON_PUBLIC"
echo " - $CLUSTER_PUBLIC_NO_NGINX"
echo " - $CLUSTER_PRIVATE_MANAGED"
echo " - $CLUSTER_PRIVATE_NO_NGINX"
    '''
  }
  dependsOn: [
    contributorRole
  ]
}

output createdClusters object = clusters
output deploymentScriptName string = deployDemo.name
