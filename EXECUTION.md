# AKS Ingress Comparison - Execution Guide

This guide explains how to deploy and validate the five-cluster AKS exposure patterns using the current files in this repo.

## Files created

- Bicep (infra + workload deployment): `deploy-aks-ingress-comparison.bicep`
- Post-deploy workloads script: `deploy-demo-workloads-all-clusters.sh`
- VM create helper: `create-private-audit-vm.sh`
- VM tools installer: `install-az-cli-ubuntu.sh`
- Guide: `EXECUTION.md`
- API source: `api1.py`
- API source: `api2.py`
- API source: `api3.py`
- Router source (for `aksnonginx`): `api-router.py`
- Managed NGINX reference manifest: `nginx-managed-config-explained.yaml`
- Cross-subscription audit script: `audit-managed-nginx-aks.sh`
- Private AKS audit script: `audit-managed-nginx-private-aks.sh`

Important: run deployment commands from this same folder so relative paths (for example `deploy-aks-ingress-comparison.bicep`) resolve correctly.

## Bicep cluster deployment (recommended for repeat demos)

Use this option when you want to recreate all 5 AKS demo clusters and their node pools. The Bicep file creates AKS clusters only and does not run in-cluster workload commands.

Prerequisites specific to this path:

1. You can create role assignments in the target resource group (Owner or User Access Administrator is required).
2. Azure CLI is logged in with sufficient AKS/networking quota.

Run:

```bash
# 1) Create/ensure resource group
az group create --name rg-aks-ingress-compare-aue --location australiaeast

# 2) Deploy all clusters + workloads
az deployment group create --resource-group rg-aks-ingress-compare-aue --template-file deploy-aks-ingress-comparison.bicep --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

Optional parameters:

- `namePrefix=<value>` to avoid cluster name conflicts in shared subscriptions.
- `kubernetesVersion=<value>` to pin a specific AKS version.

What this Bicep deployment does:

1. Creates five AKS clusters used in this comparison.
2. Adds `userpool` node pool in each cluster.
3. Creates one shared VNet for all demo clusters.
4. Creates one dedicated subnet per AKS cluster plus one dedicated subnet for the audit VM.
5. Deploys each AKS cluster into its own dedicated subnet in the shared VNet.
6. Creates the user-assigned identity used for automation.
7. Outputs cluster names, shared VNet name, subnet names, and identity details for follow-up workload steps.

After this Bicep deployment completes, run the post-deploy script to configure workloads across all clusters.

## One-command post-deploy workload rollout

This script deploys `api1`, `api2`, `api3` to all 5 clusters and then applies cluster-specific ingress/router setup:

1. `akspublicnginx`: managed ingress
2. `akspvtnginx`: managed ingress + internal managed NGINX config
3. `aksnonginx`: `api-router` + public LoadBalancer service
4. `akspvtnginxpriv`: managed ingress + internal managed NGINX config
5. `akspvtnon-nginx`: APIs only (no ingress by design)

Run:

```bash
chmod +x deploy-demo-workloads-all-clusters.sh
./deploy-demo-workloads-all-clusters.sh --resource-group rg-aks-ingress-compare-aue --name-prefix <your-prefix>
```

Azure Cloud Shell support:

You can run this script from Azure Cloud Shell (Bash) as long as the required repo files are present in the same folder.

Option 1 (recommended): clone the repository in Cloud Shell.

```bash
git clone https://github.com/kunalchandratre1/aks-nginx-ingress-retirement-audit.git
cd aks-nginx-ingress-retirement-audit
chmod +x deploy-demo-workloads-all-clusters.sh
./deploy-demo-workloads-all-clusters.sh --resource-group rg-aks-ingress-compare-aue --name-prefix <your-prefix>
```

Option 2: upload only required files to Cloud Shell and run from that folder.

Required files:

1. `deploy-demo-workloads-all-clusters.sh`
2. `api1.py`
3. `api2.py`
4. `api3.py`
5. `api-router.py`

Notes:

1. Use the same `--name-prefix` value that you used in Bicep deployment.
2. For private clusters, run this from a network path that can reach private AKS API endpoints (for example Bastion-connected VM).
3. For private cluster API reachability, Cloud Shell may not have network path. In that case, run from a VM in the VNet.

## What this deploys

- Region: `australiaeast`
- One resource group: `rg-aks-ingress-compare-aue`
- One shared VNet for the demo environment
- Dedicated subnets:
  - one subnet for `akspublicnginx`
  - one subnet for `akspvtnginx`
  - one subnet for `aksnonginx`
  - one subnet for `akspvtnginxpriv`
  - one subnet for `akspvtnon-nginx`
  - one subnet for the audit VM
- Five AKS clusters:
  - `akspublicnginx` (app routing add-on + managed NGINX public)
  - `akspvtnginx` (app routing add-on + managed NGINX private)
  - `aksnonginx` (no app routing, no ingress, public LoadBalancer service)
  - `akspvtnginxpriv` (private AKS + app routing add-on + managed internal NGINX)
  - `akspvtnon-nginx` (private AKS, no app routing, no ingress)
- Each cluster has:
  - 1 system node pool VM (`Standard_B2s`, Linux)
  - 1 user node pool VM (`Standard_B2s`, Linux)
- App namespace: `sample-api`
- Three API backends are created as separate deployments:
  - `api1`
  - `api2`
  - `api3`
- API pods are pinned to the AKS user node pool (`userpool`) using nodeSelector.
- Endpoints:
  - `/api1`
  - `/api2`
  - `/api3`
- For `aksnonginx`, path routing is provided by a small public `api-router` service (LoadBalancer)
  that forwards requests to internal `ClusterIP` services `api1`, `api2`, and `api3`.

## Private connectivity VM

Use the helper scripts in this repo to create and prepare an Ubuntu VM for private-cluster audit execution.

### Automated VM creation for private audit path

Use this helper to create a Bastion-friendly Ubuntu VM (username/password auth, no public IP) in your target VNet/subnet.

After the shared-VNet Bicep deployment, this VM should be created in the dedicated VM subnet from that shared VNet.

```bash
chmod +x create-private-audit-vm.sh
./create-private-audit-vm.sh --admin-username azureuser
```

Optional parameters:

- `--resource-group rg-aks-ingress-compare-aue`
- `--vnet-name <existing-vnet-name>`
- `--subnet-name <existing-subnet-name-used-as-vnet-anchor>`
- `--vnet-resource-group <vnet-resource-group>`
- `--vm-subnet-name snet-vm-akspvt-audit`
- `--vm-subnet-size 8` or `--vm-subnet-size 16` (default 16)
- `--vm-subnet-prefix <explicit-cidr-within-vnet>`
- `--vm-subnet-nsg-name nsg-vm-akspvt-audit`
- `--vm-name vm-akspvt-audit`

Note: with the shared-VNet deployment, the helper can reuse the pre-created VM subnet. If `--vm-subnet-prefix` is not provided and the VM subnet does not already exist, the script auto-creates a non-overlapping dedicated subnet in the target VNet using `/29` (8 IPs) or `/28` (16 IPs).

This VM has no public IP by default. Connect through Azure Bastion.

After Bastion login to the VM, install Azure CLI and kubectl:

```bash
sudo apt-get update -y
sudo apt-get install -y git
git clone https://github.com/kunalchandratre1/aks-nginx-ingress-retirement-audit.git
cd aks-nginx-ingress-retirement-audit
chmod +x install-az-cli-ubuntu.sh
./install-az-cli-ubuntu.sh
```

From inside the VM, sign in and prepare tools (if required):

```bash
az login
az account show --output table
kubectl version --client
```

Deploy `api1`, `api2`, `api3` (and cluster-specific ingress/router setup, including managed NGINX where applicable) before running the audit:

```bash
chmod +x deploy-demo-workloads-all-clusters.sh
./deploy-demo-workloads-all-clusters.sh --resource-group rg-aks-ingress-compare-aue --name-prefix <your-prefix>
```

Run private audit script from the VM (recommended for private AKS):

```bash
chmod +x audit-managed-nginx-private-aks.sh
./audit-managed-nginx-private-aks.sh
```

If script files are on your local machine, copy them to VM:

```bash
scp MANAGED_NGINX_AUDIT_SCRIPT.md azureuser@20.211.120.170:~/
scp audit-managed-nginx-aks.sh azureuser@20.211.120.170:~/
scp audit-managed-nginx-private-aks.sh azureuser@20.211.120.170:~/
```

## Prerequisites

1. Azure CLI installed and logged in.
2. kubectl installed.
3. Your account has permission to create AKS, networking, and load balancer resources.
4. Sufficient vCPU quota in `australiaeast` for 5 clusters.

Check:

```bash
az --version
kubectl version --client
az account show --output table
```

## Run steps

From your folder (Bash / WSL / Git Bash):

```bash
cd "/mnt/d/Customers/Bajaj Finance/Nginx Replacement/Codebase"
az group create --name rg-aks-ingress-compare-aue --location australiaeast
az deployment group create \
  --resource-group rg-aks-ingress-compare-aue \
  --template-file deploy-aks-ingress-comparison.bicep \
  --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

If using Git Bash on Windows path style:

```bash
cd "/d/Customers/Bajaj Finance/Nginx Replacement/Codebase"
az group create --name rg-aks-ingress-compare-aue --location australiaeast
az deployment group create \
  --resource-group rg-aks-ingress-compare-aue \
  --template-file deploy-aks-ingress-comparison.bicep \
  --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

If using PowerShell (Windows):

```powershell
Set-Location "D:\Customers\Bajaj Finance\Nginx Replacement\Codebase"
az group create --name rg-aks-ingress-compare-aue --location australiaeast
az deployment group create --resource-group rg-aks-ingress-compare-aue --template-file .\deploy-aks-ingress-comparison.bicep --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

If using WSL and Azure CLI is installed in Windows only, either install Azure CLI in WSL or run from PowerShell/Cloud Shell.

## Expected duration

- Cluster creation is the longest step.
- Typical total time: 30 to 75 minutes (depends on subscription and region load).

## Validation after deployment

After deployment completes, run the following to validate endpoints:

```bash
# Cluster 1 - public managed NGINX
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspublicnginx --overwrite-existing
kubectl get nodes -o wide
kubectl get pods,svc,ing -n sample-api -o wide
kubectl get svc -n app-routing-system nginx -o wide
kubectl get pods -n sample-api -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName

PUB_ING_IP=$(kubectl get svc -n app-routing-system nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -H "Host: myapp" "http://${PUB_ING_IP}/api1"
curl -s -H "Host: myapp" "http://${PUB_ING_IP}/api2"
curl -s -H "Host: myapp" "http://${PUB_ING_IP}/api3"

# Cluster 2 - private managed NGINX
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspvtnginx --overwrite-existing
kubectl get nodes -o wide
kubectl get pods,svc,ing -n sample-api -o wide
kubectl get nginxingresscontroller
kubectl get svc -n app-routing-system nginx-internal-0 -o wide
kubectl get pods -n sample-api -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName

PVT_ING_IP=$(kubectl get svc -n app-routing-system nginx-internal-0 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# Run these curls only from a network path that can reach the private IP
curl -s -H "Host: myapp" "http://${PVT_ING_IP}/api1"
curl -s -H "Host: myapp" "http://${PVT_ING_IP}/api2"
curl -s -H "Host: myapp" "http://${PVT_ING_IP}/api3"

# Cluster 3 - public LoadBalancer (no ingress)
az aks get-credentials -g rg-aks-ingress-compare-aue -n aksnonginx --overwrite-existing
kubectl get nodes -o wide
kubectl get pods,svc -n sample-api -o wide
kubectl get pods -n sample-api -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName

LB_IP=$(kubectl get svc sample-api-public -n sample-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://${LB_IP}/api1"
curl -s "http://${LB_IP}/api2"
curl -s "http://${LB_IP}/api3"
```

## Private ingress testing note (cluster 2)

Cluster 2 is intentionally private-only. Test from:

- VM in same VNet
- VM in peered VNet
- On-prem over VPN/ExpressRoute
- Jumpbox/Bastion-connected VM

You can also test from inside cluster 2:

```bash
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspvtnginx --overwrite-existing
PVT_ING_IP=$(kubectl get svc -n app-routing-system nginx-internal-0 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl -n sample-api run curltest --image=curlimages/curl:8.9.1 --restart=Never --command -- \
  sh -c "curl -s -H 'Host: myapp' http://${PVT_ING_IP}/api1"
kubectl -n sample-api delete pod curltest --ignore-not-found=true
```

## Final testing curl instructions

Use one of the following blocks after deployment to run final end-to-end API checks for all clusters.

### Bash (Cloud Shell / Git Bash / WSL)

```bash
# Set this to the same prefix used in Bicep deployment. Keep empty if no prefix was used.
NAME_PREFIX="nb67hg"
if [ -n "$NAME_PREFIX" ]; then PREFIX="${NAME_PREFIX}-"; else PREFIX=""; fi

CL1_NAME="${PREFIX}akspublicnginx"
CL2_NAME="${PREFIX}akspvtnginx"
CL3_NAME="${PREFIX}aksnonginx"
CL4_NAME="${PREFIX}akspvtnginxpriv"
CL5_NAME="${PREFIX}akspvtnon-nginx"

# --------------------------------------------
# Cluster 1 final test (public managed NGINX)
# --------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n "$CL1_NAME" --overwrite-existing
CL1_IP=$(kubectl get svc -n app-routing-system nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster1 IP: ${CL1_IP}"

curl -s -H "Host: myapp" "http://${CL1_IP}/api1" ; echo
curl -s -H "Host: myapp" "http://${CL1_IP}/api2" ; echo
curl -s -H "Host: myapp" "http://${CL1_IP}/api3" ; echo


# --------------------------------------------
# Cluster 2 final test (private managed NGINX)
# --------------------------------------------
# Run from a machine/network path that can reach private AKS VNet addresses.
az aks get-credentials -g rg-aks-ingress-compare-aue -n "$CL2_NAME" --overwrite-existing
CL2_IP=$(kubectl get svc -n app-routing-system nginx-internal-0 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster2 private IP: ${CL2_IP}"

curl -s -H "Host: myapp" "http://${CL2_IP}/api1" ; echo
curl -s -H "Host: myapp" "http://${CL2_IP}/api2" ; echo
curl -s -H "Host: myapp" "http://${CL2_IP}/api3" ; echo


# -----------------------------------------------------------------
# Cluster 2 alternative test from inside cluster (if no network path)
# -----------------------------------------------------------------
kubectl -n sample-api run curltest --image=curlimages/curl:8.9.1 --restart=Never --command -- sh -c \
  "curl -s -H 'Host: myapp' http://${CL2_IP}/api1; echo; \
   curl -s -H 'Host: myapp' http://${CL2_IP}/api2; echo; \
   curl -s -H 'Host: myapp' http://${CL2_IP}/api3; echo"
kubectl -n sample-api delete pod curltest --ignore-not-found=true


# -------------------------------------------------
# Cluster 3 final test (public LoadBalancer service)
# -------------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n "$CL3_NAME" --overwrite-existing
CL3_IP=$(kubectl get svc sample-api-public -n sample-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster3 public LB IP: ${CL3_IP}"

curl -s "http://${CL3_IP}/api1" ; echo
curl -s "http://${CL3_IP}/api2" ; echo
curl -s "http://${CL3_IP}/api3" ; echo


# --------------------------------------------
# Cluster 4 final test (private AKS + managed NGINX)
# --------------------------------------------
# Run from a machine/network path that can reach private AKS VNet addresses.
az aks get-credentials -g rg-aks-ingress-compare-aue -n "$CL4_NAME" --overwrite-existing
CL4_IP=$(kubectl get svc -n app-routing-system nginx-internal-0 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster4 private IP: ${CL4_IP}"

curl -s -H "Host: myapp" "http://${CL4_IP}/api1" ; echo
curl -s -H "Host: myapp" "http://${CL4_IP}/api2" ; echo
curl -s -H "Host: myapp" "http://${CL4_IP}/api3" ; echo


# -------------------------------------------------
# Cluster 5 final test (private AKS, no ingress)
# -------------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n "$CL5_NAME" --overwrite-existing

# Run inside cluster because there is no ingress/public endpoint by design.
kubectl -n sample-api run curltest --image=curlimages/curl:8.9.1 --restart=Never --command -- sh -c \
  "curl -s http://api1.sample-api.svc.cluster.local; echo; \
   curl -s http://api2.sample-api.svc.cluster.local; echo; \
   curl -s http://api3.sample-api.svc.cluster.local; echo"
kubectl -n sample-api delete pod curltest --ignore-not-found=true
```

### PowerShell (Windows PowerShell / pwsh)

```powershell
# --------------------------------------------
# Cluster 1 final test (public managed NGINX)
# --------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspublicnginx --overwrite-existing
$CL1_IP = kubectl get svc -n app-routing-system nginx -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
Write-Host "Cluster1 IP: $CL1_IP"

curl.exe -s -H "Host: myapp" "http://$CL1_IP/api1"; Write-Host
curl.exe -s -H "Host: myapp" "http://$CL1_IP/api2"; Write-Host
curl.exe -s -H "Host: myapp" "http://$CL1_IP/api3"; Write-Host


# --------------------------------------------
# Cluster 2 final test (private managed NGINX)
# --------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspvtnginx --overwrite-existing
$CL2_IP = kubectl get svc -n app-routing-system nginx-internal-0 -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
Write-Host "Cluster2 private IP: $CL2_IP"

curl.exe -s -H "Host: myapp" "http://$CL2_IP/api1"; Write-Host
curl.exe -s -H "Host: myapp" "http://$CL2_IP/api2"; Write-Host
curl.exe -s -H "Host: myapp" "http://$CL2_IP/api3"; Write-Host

# If your machine cannot reach private IP ranges, run inside cluster 2:
kubectl -n sample-api run curltest --image=curlimages/curl:8.9.1 --restart=Never --command -- sh -c "curl -s -H 'Host: myapp' http://$CL2_IP/api1; echo; curl -s -H 'Host: myapp' http://$CL2_IP/api2; echo; curl -s -H 'Host: myapp' http://$CL2_IP/api3; echo"
kubectl -n sample-api delete pod curltest --ignore-not-found=true


# -------------------------------------------------
# Cluster 3 final test (public LoadBalancer service)
# -------------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n aksnonginx --overwrite-existing
$CL3_IP = kubectl get svc sample-api-public -n sample-api -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
Write-Host "Cluster3 public LB IP: $CL3_IP"

curl.exe -s "http://$CL3_IP/api1"; Write-Host
curl.exe -s "http://$CL3_IP/api2"; Write-Host
curl.exe -s "http://$CL3_IP/api3"; Write-Host
```

Expected result:

- Each response is JSON.
- endpoint should match api1/api2/api3.
- cluster should match the current cluster under test.
- podHostname should be present.
- pathReceived should show the requested path.

## Troubleshooting

```bash
# Resource and node pool state
az aks list -g rg-aks-ingress-compare-aue -o table
az aks nodepool list -g rg-aks-ingress-compare-aue --cluster-name akspublicnginx -o table
az aks nodepool list -g rg-aks-ingress-compare-aue --cluster-name akspvtnginx -o table
az aks nodepool list -g rg-aks-ingress-compare-aue --cluster-name aksnonginx -o table
az aks nodepool list -g rg-aks-ingress-compare-aue --cluster-name akspvtnginxpriv -o table
az aks nodepool list -g rg-aks-ingress-compare-aue --cluster-name akspvtnon-nginx -o table

# Kubernetes diagnostics
kubectl get events -A --sort-by=.lastTimestamp | tail -n 100
kubectl get all -n app-routing-system
kubectl get nginxingresscontroller
kubectl describe ingress -n sample-api sample-api-ingress
kubectl describe svc -n app-routing-system nginx
kubectl get pods -n sample-api -o wide
kubectl logs -n sample-api deployment/api1
kubectl logs -n sample-api deployment/api2
kubectl logs -n sample-api deployment/api3
kubectl logs -n sample-api deployment/api-router
```

## Cleanup

Cleanup command:

```bash
az group delete --name rg-aks-ingress-compare-aue --yes --no-wait
```

## Notes

- This implementation uses AKS application routing with managed NGINX for clusters 1 and 2, as requested.
- Cluster 2 uses the app-routing NginxIngressController CRD to enforce internal/private load balancer mode.
- No TLS, no certificates, and HTTP only for analysis/demo purpose.
