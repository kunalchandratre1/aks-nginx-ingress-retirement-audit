# AKS Ingress Comparison - Execution Guide

This guide explains how to run the deployment script and validate the five-cluster AKS exposure patterns.

## Files created

- Script: `deploy-aks-ingress-comparison.sh`
- Guide: `EXECUTION.md`
- API source: `api1.py`
- API source: `api2.py`
- API source: `api3.py`
- Router source (for `aksnonginx`): `api-router.py`
- Managed NGINX reference manifest: `nginx-managed-config-explained.yaml`
- Cross-subscription audit script: `audit-managed-nginx-aks.sh`
- Private AKS audit script: `audit-managed-nginx-private-aks.sh`

Important: run the script from this same folder so it can read these source files and create Kubernetes ConfigMaps from them.

## What this deploys

- Region: `australiaeast`
- One resource group: `rg-aks-ingress-compare-aue`
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

## Private connectivity VM (added)

An Ubuntu VM was created in the same resource group to test private-cluster connectivity and run private audit scripts.

- VM name: `vm-akspvt-audit`
- Resource group: `rg-aks-ingress-compare-aue`
- VNet/Subnet: `vnet-akspvtnginxpriv` / `snet-akspvtnginxpriv`
- Private IP: `10.40.1.63`
- Public IP (for SSH): `20.211.120.170`

Connect:

```bash
ssh azureuser@20.211.120.170
```

From inside the VM, sign in and prepare tools (if required):

```bash
az login
az account show --output table
kubectl version --client
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
4. Sufficient vCPU quota in `australiaeast` for 3 clusters.

Check:

```bash
az --version
kubectl version --client
az account show --output table
```

## Run steps

From your folder:

```bash
cd "/mnt/d/Customers/Bajaj Finance/Nginx Replacement/Codebase"
chmod +x deploy-aks-ingress-comparison.sh
./deploy-aks-ingress-comparison.sh
```

If using Git Bash on Windows:

```bash
cd "/d/Customers/Bajaj Finance/Nginx Replacement/Codebase"
chmod +x deploy-aks-ingress-comparison.sh
./deploy-aks-ingress-comparison.sh
```

If using WSL and Azure CLI is installed in Windows only, install Azure CLI in WSL or run in Azure Cloud Shell.

## Expected duration

- Cluster creation is the longest step.
- Typical total time: 30 to 75 minutes (depends on subscription and region load).

## Validation after deployment

The script prints final IPs and curl examples. You can also run:

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
# --------------------------------------------
# Cluster 1 final test (public managed NGINX)
# --------------------------------------------
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspublicnginx --overwrite-existing
CL1_IP=$(kubectl get svc -n app-routing-system nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster1 IP: ${CL1_IP}"

curl -s -H "Host: myapp" "http://${CL1_IP}/api1" ; echo
curl -s -H "Host: myapp" "http://${CL1_IP}/api2" ; echo
curl -s -H "Host: myapp" "http://${CL1_IP}/api3" ; echo


# --------------------------------------------
# Cluster 2 final test (private managed NGINX)
# --------------------------------------------
# Run from a machine/network path that can reach private AKS VNet addresses.
az aks get-credentials -g rg-aks-ingress-compare-aue -n akspvtnginx --overwrite-existing
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
az aks get-credentials -g rg-aks-ingress-compare-aue -n aksnonginx --overwrite-existing
CL3_IP=$(kubectl get svc sample-api-public -n sample-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Cluster3 public LB IP: ${CL3_IP}"

curl -s "http://${CL3_IP}/api1" ; echo
curl -s "http://${CL3_IP}/api2" ; echo
curl -s "http://${CL3_IP}/api3" ; echo
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

Cleanup is intentionally commented in the script. If needed:

```bash
az group delete --name rg-aks-ingress-compare-aue --yes --no-wait
```

## Notes

- This implementation uses AKS application routing with managed NGINX for clusters 1 and 2, as requested.
- Cluster 2 uses the app-routing NginxIngressController CRD to enforce internal/private load balancer mode.
- No TLS, no certificates, and HTTP only for analysis/demo purpose.
