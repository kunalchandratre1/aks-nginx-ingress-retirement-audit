# NGINX (Managed + OSS ingress-nginx) Audit for AKS

This guide covers audit execution for both managed NGINX and OSS ingress-nginx using two scripts:

1. `audit-managed-nginx-aks.sh` for targeted AKS clusters
2. `audit-managed-nginx-private-aks.sh` for targeted private AKS checks

Recommended execution environment:

- Run `audit-managed-nginx-aks.sh` from Azure Cloud Shell (Bash) when the AKS API server is publicly accessible from Cloud Shell.
- If the cluster API server is public but restricted by authorized IP ranges, run `audit-managed-nginx-aks.sh` from a location whose source IP is allowed by that cluster.
- Run `audit-managed-nginx-private-aks.sh` from a Linux VM with network reachability to private AKS API endpoints.

Both scripts are read-only against Azure and Kubernetes resources. They only write local output files and temporary kubeconfig data.

## Scope and Targeting

Full-subscription scanning is removed.

You must provide explicit targets in each script using `TARGETS` with this format:

```bash
"<subscription_id>|<resource_group>|<cluster_name>"
```

Format callout (required order):

- `Sub|RG|AKS`
- `subscription_id|resource_group|cluster_name`

Valid example:

```bash
"ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|akspublicnginx"
```

Invalid examples:

```bash
# Wrong order
"akspublicnginx|rg-aks-ingress-compare-aue|ba43c91f-2d76-4000-a7ad-24750cab54c3"

# Wrong order
"akspublicnginx|ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue"
```

Example:

```bash
TARGETS=(
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|akspublicnginx"
  "ba43c91f-2d76-4000-a7ad-24750cab54c3|rg-aks-ingress-compare-aue|akspvtnginxpriv"
)
```

If `TARGETS` is empty, the script exits without scanning.

## Output Columns

Both scripts write CSV with these columns:

- `subscription_name`
- `subscription_id`
- `resource_group`
- `cluster_name`
- `arm_app_routing_enabled`
- `k8s_api_reachable`
- `k8s_managed_nginx_observed`
- `managed_ingress_namespaces`
- `k8s_oss_nginx_observed`
- `oss_nginx_ingress_namespaces`

## What Is Detected

1. ARM app routing status
- From `ingressProfile.webAppRouting.enabled`
- `yes` when true
- `no` when false, null, or missing
- `unknown` when ARM query fails

2. AKS managed NGINX usage
- Detects `nginxingresscontroller.approuting.kubernetes.azure.com`
- Maps namespaces using managed ingress classes

3. OSS ingress-nginx usage
- Detects ingress classes where controller is `k8s.io/ingress-nginx`
- Detects ingress-nginx controller workloads via label `app.kubernetes.io/name=ingress-nginx`
- Maps namespaces using OSS ingress classes

4. Private/unreachable behavior
- If Kubernetes API cannot be reached, Kubernetes-derived columns are set to `unknown` with explanatory markers

## Prerequisites

Required tools:

- Bash
- Azure CLI (`az`)
- `kubectl`
- `mktemp`, `sort`, `paste`, `column`

Required access:

- Azure permission to read target subscriptions and AKS metadata
- Permission for `az aks get-credentials`
- Kubernetes RBAC to read namespaces, ingresses, ingress classes, and managed NGINX CRD resources

Optional checks:

```bash
az version
kubectl version --client
az account list -o table
```

## VM Prerequisites for Private AKS

Run private checks from an environment that can reach private API endpoints:

- VM in same VNet as AKS
- VM in peered VNet
- On-prem via VPN or ExpressRoute

Network and DNS:

- Connectivity to private AKS API endpoints on 443
- DNS resolution for private AKS FQDNs (usually via linked Private DNS zone)

Connectivity checks from Linux VM (run before private script):

```bash
# 1) Confirm tools
az version >/dev/null
kubectl version --client >/dev/null

# 2) Set one private target to validate
SUB_ID="ba43c91f-2d76-4000-a7ad-24750cab54c3"
RG_NAME="rg-aks-ingress-compare-aue"
AKS_NAME="akspvtnon-nginx"

# 3) Resolve private AKS FQDN from ARM
AKS_PRIVATE_FQDN="$(az aks show --subscription "$SUB_ID" -g "$RG_NAME" -n "$AKS_NAME" --query privateFqdn -o tsv)"
echo "Private FQDN: $AKS_PRIVATE_FQDN"

# 4) DNS resolution test
nslookup "$AKS_PRIVATE_FQDN"

# 5) TCP 443 reachability test
nc -vz "$AKS_PRIVATE_FQDN" 443

# 6) Kubernetes API probe (expect 401/403 or response headers if reachable)
curl -kI --connect-timeout 10 "https://$AKS_PRIVATE_FQDN/"

# 7) Credential + API test
az account set --subscription "$SUB_ID"
az aks get-credentials -g "$RG_NAME" -n "$AKS_NAME" --overwrite-existing
kubectl get ns --request-timeout=10s
```

Interpretation:

- `nslookup` failure: DNS link/config issue for private endpoint zone.
- `nc -vz ... 443` failure: network route, NSG, firewall, or peering issue.
- `kubectl get ns` failure after successful DNS/TCP: RBAC or auth context issue.

Ubuntu or Debian setup example:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl apt-transport-https gnupg lsb-release bsdextrautils coreutils
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo az aks install-cli
```

## Configure and Run

1. Update `TARGETS` in scripts:

- `audit-managed-nginx-aks.sh`
- `audit-managed-nginx-private-aks.sh`

2. Authenticate and validate context:

```bash
az login
az account list -o table
```

3. Run public/main targeted audit from Azure Cloud Shell (Bash):

```bash
chmod +x audit-managed-nginx-aks.sh
./audit-managed-nginx-aks.sh
```

If the cluster is public but protected by authorized IP ranges:

- Do not assume Azure Cloud Shell will be able to reach the Kubernetes API.
- Run `audit-managed-nginx-aks.sh` from a machine or network whose source IP is included in the cluster's allowed IP ranges.
- Examples: corporate workstation, jump box, approved VM, or any network path explicitly allowed on the AKS API server.

4. Run private targeted audit from Linux VM:

```bash
chmod +x audit-managed-nginx-private-aks.sh
./audit-managed-nginx-private-aks.sh
```

5. If you copied script files from Windows to Linux VM, normalize line endings once before execution:

```bash
sed -i 's/\r$//' audit-managed-nginx-private-aks.sh
```

## Windows Laptop Execution (Private AKS)

Use this option when private AKS API endpoints are reachable from your Windows laptop network.

Script file:

- `audit-managed-nginx-private-aks-windows.ps1`

### Prerequisites on Windows

- PowerShell 7+ (recommended)
- Azure CLI (`az`) available in PATH
- `kubectl` available in PATH
- Network + DNS reachability from laptop to private AKS API endpoints

Quick checks:

```powershell
az version
kubectl version --client
```

### Configure Targets

Open `audit-managed-nginx-private-aks-windows.ps1` and update `$Targets` entries in this format:

```powershell
@{ SubscriptionId = "<subscription_id>"; ResourceGroup = "<resource_group>"; ClusterName = "<cluster_name>" }
```

Example:

```powershell
@{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "akspvtnginxpriv" }
```

### Run from PowerShell

```powershell
cd "C:\path\to\aks-nginx-ingress-retirement-audit"
powershell -ExecutionPolicy Bypass -File .\audit-managed-nginx-private-aks-windows.ps1
```

### Private Cluster Reachability Test from Windows Laptop

Run these checks before executing the Windows private script:

```powershell
# 1) Set one private target
$SUB_ID = "ba43c91f-2d76-4000-a7ad-24750cab54c3"
$RG_NAME = "rg-aks-ingress-compare-aue"
$AKS_NAME = "akspvtnon-nginx"

# 2) Resolve private AKS FQDN from ARM
$AKS_PRIVATE_FQDN = az aks show --subscription $SUB_ID -g $RG_NAME -n $AKS_NAME --query privateFqdn -o tsv
Write-Host "Private FQDN: $AKS_PRIVATE_FQDN"

# 3) DNS resolution test
Resolve-DnsName $AKS_PRIVATE_FQDN

# 4) TCP 443 reachability test
Test-NetConnection $AKS_PRIVATE_FQDN -Port 443

# 5) HTTPS probe (expect 401/403 or headers if reachable)
curl.exe -k -I --connect-timeout 10 "https://$AKS_PRIVATE_FQDN/"

# 6) Credential + API test
az account set --subscription $SUB_ID
az aks get-credentials -g $RG_NAME -n $AKS_NAME --overwrite-existing
kubectl get ns --request-timeout=10s
```

Interpretation for Windows tests:

- `Resolve-DnsName` fails: DNS path/link issue for private AKS endpoint zone.
- `Test-NetConnection ... -Port 443` with `TcpTestSucceeded=False`: routing, NSG, firewall, or peering issue.
- `kubectl get ns` fails after DNS/TCP succeed: RBAC or kube context/auth issue.

### Troubleshooting When Script Returns `NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED`

If the script reports `NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED`, verify the same target manually from the execution environment:

```bash
az account show -o table
az aks show -g BFL-Bpay-UAT-K8-New -n AKS-BPAY-UAT -o json
az aks get-credentials -g BFL-Bpay-UAT-K8-New -n AKS-BPAY-UAT --overwrite-existing
echo $?
kubectl get ns --request-timeout=10s
```

How to interpret:

- `az aks show` fails: Azure read access or wrong subscription/context issue.
- `az aks get-credentials` fails: AKS credential access/RBAC issue or cluster access restriction before kubeconfig is fetched.
- `echo $?` returns non-zero after `az aks get-credentials`: the credential fetch failed.
- `az aks get-credentials` succeeds but `kubectl get ns` fails: Kubernetes API reachability, authorized IP range restriction, DNS, or Kubernetes auth/RBAC issue.

Important:

- Run the Bash scripts with `bash script-name.sh` or `./script-name.sh`, not `sh script-name.sh`.
- These scripts use Bash-specific syntax such as arrays, `[[ ... ]]`, and lowercase expansion.

Output:

- CSV file: `managed_nginx_private_aks_audit_windows_YYYYMMDD_HHMMSS.csv`
- Console table preview of first rows

## Safety Notes

- No `az delete`, `kubectl delete`, `az update`, or `kubectl apply` operations are used.
- The scripts overwrite local kubeconfig context for execution and clean up temporary kubeconfig files.

## Post-Run Filtering Logic

Use the generated CSV from either script to build final action lists.

Assume your latest output file is in `CSV_FILE`:

```bash
CSV_FILE="managed_nginx_audit_YYYYMMDD_HHMMSS.csv"
# or
CSV_FILE="managed_nginx_private_aks_audit_YYYYMMDD_HHMMSS.csv"
```

### 1) Reachable Clusters Only

```bash
awk -F',' 'NR==1 || $6=="\"yes\""' "$CSV_FILE" > reachable_clusters.csv
```

### 2) OSS ingress-nginx In Use (Primary Retirement Scope)

```bash
awk -F',' 'NR==1 || ($6=="\"yes\"" && $9=="\"yes\"")' "$CSV_FILE" > nginx_oss_replacement_candidates.csv
```

### 3) AKS Managed NGINX In Use (Evaluate Managed Replacement Path)

```bash
awk -F',' 'NR==1 || ($6=="\"yes\"" && $7=="\"yes\"")' "$CSV_FILE" > nginx_managed_replacement_candidates.csv
```

### 4) Follow-Up List (Unreachable or Unknown Kubernetes State)

```bash
awk -F',' 'NR==1 || $6!="\"yes\""' "$CSV_FILE" > nginx_followup_unreachable_or_unknown.csv
```

### 5) Quick Console Preview

```bash
column -s, -t nginx_oss_replacement_candidates.csv | head -n 50
column -s, -t nginx_managed_replacement_candidates.csv | head -n 50
column -s, -t nginx_followup_unreachable_or_unknown.csv | head -n 50
```

Interpretation:

- `nginx_oss_replacement_candidates.csv`: clusters where OSS ingress-nginx was observed and replacement should be prioritized.
- `nginx_managed_replacement_candidates.csv`: clusters using AKS managed NGINX where managed ingress replacement options should be evaluated.
- `nginx_followup_unreachable_or_unknown.csv`: clusters that require rerun from a network-reachable environment before final sign-off.

## Manual Investigation for `NONE_USING_OSS_CLASS`

If a cluster shows:

- `k8s_oss_nginx_observed=yes`
- `oss_nginx_ingress_namespaces=NONE_USING_OSS_CLASS`

then OSS ingress-nginx was detected, but no current Ingress resource was found explicitly using an OSS ingress-nginx class.

At that point, do not decide replacement vs removal from the CSV alone.

Run this helper script:

- `investigate-oss-nginx-candidate.sh`

Purpose of the helper:

- Lists ingress classes and whether one is marked as default
- Lists all ingress resources, including classless ingress objects
- Lists ingress resources explicitly using OSS ingress-nginx classes
- Lists ingress-nginx controller workloads, pods, and services
- Lists likely related ConfigMaps, Secrets, and Helm releases

Run it:

```bash
chmod +x investigate-oss-nginx-candidate.sh
./investigate-oss-nginx-candidate.sh
```

What to conclude from the helper output:

- If classless ingress resources exist and an OSS ingress class is default, replacement is likely still required.
- If ingress-nginx workloads and services exist but no ingress uses them, investigate whether they are leftover or used for non-Ingress traffic patterns.
- If no controller workloads, no relevant services, and no usable ingress classes remain, removal/cleanup is more likely than replacement.
- If there is still uncertainty, treat it as a manual review candidate before deciding.

## Copy CSV from Linux VM to Laptop

If you ran `audit-managed-nginx-private-aks.sh` on a Linux VM and want to download the CSV to your laptop:

```bash
scp azureuser@13.70.109.9:~/managed_nginx_private_aks_audit_*.csv .
```

Notes:

- Run the command from a writable local folder on your laptop.
- If SSH asks to trust the host fingerprint, confirm only after verifying it is your VM.
- If the VM uses password authentication, SCP prompts for the same VM password.
