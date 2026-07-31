# Create Test Infra

This guide covers only infrastructure creation for the AKS comparison environment.

## Scope

This creates:

- Resource group `rg-aks-ingress-compare-aue`
- Shared VNet for the demo environment
- Dedicated subnets:
  - one subnet for `akspublicnginx`
  - one subnet for `akspvtnginx`
  - one subnet for `aksnonginx`
  - one subnet for `akspvtnginxpriv`
  - one subnet for `akspvtnon-nginx`
  - one subnet for the audit VM
- Five AKS clusters:
  - `akspublicnginx` (managed NGINX public)
  - `akspvtnginx` (managed NGINX private mode on public cluster)
  - `aksnonginx` (no ingress, public LB path)
  - `akspvtnginxpriv` (private AKS + managed NGINX)
  - `akspvtnon-nginx` (private AKS, no ingress)
- `userpool` node pool in each cluster
- User-assigned identity used by deployment automation

## Prerequisites

1. Azure CLI installed and logged in.
2. Permissions to create AKS/networking resources in the target subscription and resource group.
3. Sufficient vCPU quota in `australiaeast`.

Check:

```bash
az --version
az account show --output table
```

## Step 1: Create Resource Group

```bash
az group create --name rg-aks-ingress-compare-aue --location australiaeast
```

## Step 2: Deploy Infra (Bicep)

Run from the repository folder where `deploy-aks-ingress-comparison.bicep` exists.

```bash
az deployment group create \
  --resource-group rg-aks-ingress-compare-aue \
  --template-file deploy-aks-ingress-comparison.bicep \
  --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

Optional parameters:

- `namePrefix=<value>` to avoid name collisions
- `kubernetesVersion=<value>` to pin a specific AKS version

## PowerShell Variant

```powershell
Set-Location "C:\path\to\aks-nginx-ingress-retirement-audit"
az group create --name rg-aks-ingress-compare-aue --location australiaeast
az deployment group create --resource-group rg-aks-ingress-compare-aue --template-file .\deploy-aks-ingress-comparison.bicep --parameters location=australiaeast nodeCount=1 nodeVmSize=Standard_B2s namePrefix=<your-prefix>
```

## Next Step

After infra creation, continue with workload rollout and audit execution from `NGINX_AUDIT_SCRIPT.md`.

## Cleanup

```bash
az group delete --name rg-aks-ingress-compare-aue --yes --no-wait
```
