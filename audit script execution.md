# Audit Script Execution

This guide covers workload rollout and audit script execution only.

## Scope

This runs:

1. Workload rollout (`api1`, `api2`, `api3`) across all clusters
2. VM creation for private-cluster access
3. VM setup (Azure CLI, kubectl)
4. Private AKS audit script execution

Use this after infra is already created.

## Prerequisites

1. Infra deployment is complete (see `create test infra.md`).
2. You know the `namePrefix` used during deployment.
3. You can connect to the VM using Azure Bastion.

## Step 1: Deploy Workloads (from local machine or Cloud Shell)

```bash
chmod +x deploy-demo-workloads-all-clusters.sh
./deploy-demo-workloads-all-clusters.sh --resource-group rg-aks-ingress-compare-aue --name-prefix <your-prefix>
```

This deploys `api1`, `api2`, `api3` and applies cluster-specific ingress/router config.

## Step 2: Create Audit VM

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
- `--vm-subnet-size 8` or `--vm-subnet-size 16`
- `--vm-subnet-prefix <explicit-cidr-within-vnet>`
- `--vm-subnet-nsg-name nsg-vm-akspvt-audit`
- `--vm-name vm-akspvt-audit`

## Step 3: Connect to VM and install tools

After Bastion login:

```bash
sudo apt-get update -y
sudo apt-get install -y git
git clone https://github.com/kunalchandratre1/aks-nginx-ingress-retirement-audit.git
cd aks-nginx-ingress-retirement-audit
chmod +x install-az-cli-ubuntu.sh
./install-az-cli-ubuntu.sh
```

## Step 4: Login inside VM

```bash
az login
az account show --output table
kubectl version --client
```

## Step 5: Ensure workloads are present from VM context

Run this if workloads were not rolled out earlier from your local machine/network path:

```bash
chmod +x deploy-demo-workloads-all-clusters.sh
./deploy-demo-workloads-all-clusters.sh --resource-group rg-aks-ingress-compare-aue --name-prefix <your-prefix>
```

## Step 6: Run private AKS audit script

```bash
chmod +x audit-managed-nginx-private-aks.sh
./audit-managed-nginx-private-aks.sh
```

The script prints CSV output in terminal and writes a timestamped CSV file.

## Optional: Run cross-subscription audit script

```bash
chmod +x audit-managed-nginx-aks.sh
./audit-managed-nginx-aks.sh
```
