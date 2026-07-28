#!/usr/bin/env bash
set -euo pipefail

# Creates a Bastion-friendly Ubuntu VM for running private AKS audit scripts.
# Default behavior prefers the shared demo VNet (*-vnet-aks-demo) in the resource group.

RESOURCE_GROUP="rg-aks-ingress-compare-aue"
LOCATION=""
VM_NAME="vm-akspvt-audit"
VNET_NAME=""
SUBNET_NAME=""
VNET_RESOURCE_GROUP=""
VM_SUBNET_NAME="snet-vm-akspvt-audit"
DEFAULT_VM_SUBNET_PREFIX=""
VM_SUBNET_PREFIX="${DEFAULT_VM_SUBNET_PREFIX}"
VM_SUBNET_PREFIX_EXPLICIT="0"
VM_SUBNET_SIZE="16"
VM_SUBNET_NSG_NAME="nsg-vm-akspvt-audit"
VM_SIZE="Standard_B2s"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --resource-group <name>       Resource group name (default: ${RESOURCE_GROUP})
  --location <region>           Azure region. If omitted, uses resource group location.
  --vm-name <name>              VM name (default: ${VM_NAME})
  --vnet-name <name>            Existing VNet name (optional; auto-discovered when omitted)
  --subnet-name <name>          Existing subnet name used only as VNet anchor (optional)
  --vnet-resource-group <name>  Resource group of VNet/subnet (optional)
  --vm-subnet-name <name>       Dedicated subnet name for VM (default: ${VM_SUBNET_NAME})
  --vm-subnet-prefix <cidr>     Dedicated subnet CIDR (optional; if omitted script auto-finds free CIDR)
  --vm-subnet-size <8|16>       Dedicated subnet size in IPs when CIDR is auto-selected (default: ${VM_SUBNET_SIZE})
  --vm-subnet-nsg-name <name>   NSG name to create and attach at VM subnet level (default: ${VM_SUBNET_NSG_NAME})
  --vm-size <size>              VM size (default: ${VM_SIZE})
  --admin-username <user>       Admin username for Ubuntu VM
  --admin-password <pass>       Admin password for Ubuntu VM
  -h, --help                    Show this help

Examples:
  $0 --admin-username azureuser
  $0 --resource-group rg-aks-ingress-compare-aue --admin-username azureuser
  $0 --admin-username azureuser --vnet-name my-vnet --subnet-name my-subnet --vnet-resource-group my-network-rg
  $0 --admin-username azureuser --vm-subnet-name snet-audit --vm-subnet-size 8 --vm-subnet-nsg-name nsg-audit
  $0 --admin-username azureuser --vm-subnet-name snet-audit --vm-subnet-prefix 10.224.255.240/28 --vm-subnet-nsg-name nsg-audit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      RESOURCE_GROUP="$2"; shift 2 ;;
    --location)
      LOCATION="$2"; shift 2 ;;
    --vm-name)
      VM_NAME="$2"; shift 2 ;;
    --vnet-name)
      VNET_NAME="$2"; shift 2 ;;
    --subnet-name)
      SUBNET_NAME="$2"; shift 2 ;;
    --vnet-resource-group)
      VNET_RESOURCE_GROUP="$2"; shift 2 ;;
    --vm-subnet-name)
      VM_SUBNET_NAME="$2"; shift 2 ;;
    --vm-subnet-prefix)
      VM_SUBNET_PREFIX="$2"; VM_SUBNET_PREFIX_EXPLICIT="1"; shift 2 ;;
    --vm-subnet-size)
      VM_SUBNET_SIZE="$2"; shift 2 ;;
    --vm-subnet-nsg-name)
      VM_SUBNET_NSG_NAME="$2"; shift 2 ;;
    --vm-size)
      VM_SIZE="$2"; shift 2 ;;
    --admin-username)
      ADMIN_USERNAME="$2"; shift 2 ;;
    --admin-password)
      ADMIN_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI not found. Install Azure CLI first." >&2
  exit 1
fi

if [[ -z "${ADMIN_USERNAME}" ]]; then
  read -r -p "Enter admin username: " ADMIN_USERNAME
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  read -r -s -p "Enter admin password: " ADMIN_PASSWORD
  echo
fi

if [[ -z "${ADMIN_USERNAME}" || -z "${ADMIN_PASSWORD}" ]]; then
  echo "Admin username and password are required." >&2
  exit 1
fi

if [[ "${VM_SUBNET_SIZE}" != "8" && "${VM_SUBNET_SIZE}" != "16" ]]; then
  echo "--vm-subnet-size must be either 8 or 16." >&2
  exit 1
fi

if [[ -z "${LOCATION}" ]]; then
  LOCATION="$(az group show --name "${RESOURCE_GROUP}" --query location -o tsv 2>/dev/null || true)"
fi

if [[ -z "${LOCATION}" ]]; then
  echo "Unable to determine location. Set --location explicitly or ensure resource group exists." >&2
  exit 1
fi

echo "Using resource group: ${RESOURCE_GROUP}"
echo "Using location: ${LOCATION}"
echo "Resolving target VNet/subnet..."

discover_shared_vnet() {
  local found_vnets
  local vnet_count

  found_vnets="$(az network vnet list -g "${RESOURCE_GROUP}" --query "[?contains(name,'vnet-aks-demo')].name" -o tsv 2>/dev/null | tr -d '\r' || true)"
  vnet_count="$(printf '%s\n' "${found_vnets}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${vnet_count}" == "1" ]]; then
    printf '%s\n' "${found_vnets}" | sed -n '1p'
    return 0
  fi

  return 1
}

discover_subnet_id() {
  local node_rg_list
  local node_rg
  local vnet_name
  local subnet_id

  # Prefer private cluster node resource groups first.
  node_rg_list="$(az aks list -g "${RESOURCE_GROUP}" --query "[?apiServerAccessProfile.enablePrivateCluster==\`true\`].nodeResourceGroup" -o tsv 2>/dev/null | tr -d '\r' || true)"

  if [[ -z "${node_rg_list}" ]]; then
    node_rg_list="$(az aks list -g "${RESOURCE_GROUP}" --query "[].nodeResourceGroup" -o tsv 2>/dev/null | tr -d '\r' || true)"
  fi

  while IFS= read -r node_rg; do
    [[ -z "${node_rg}" ]] && continue

    while IFS= read -r vnet_name; do
      [[ -z "${vnet_name}" ]] && continue

      subnet_id="$(az network vnet subnet show -g "${node_rg}" --vnet-name "${vnet_name}" -n "aks-subnet" --query id -o tsv 2>/dev/null || true)"
      if [[ -z "${subnet_id}" ]]; then
        subnet_id="$(az network vnet subnet list -g "${node_rg}" --vnet-name "${vnet_name}" --query "[?name!='aks-appgateway' && name!='aks-virtualkubelet'][0].id" -o tsv 2>/dev/null || true)"
      fi

      if [[ -n "${subnet_id}" ]]; then
        echo "${subnet_id}"
        return 0
      fi
    done < <(az network vnet list -g "${node_rg}" --query "[].name" -o tsv 2>/dev/null | tr -d '\r' || true)
  done < <(printf '%s\n' "${node_rg_list}")

  return 1
}

ip_to_int() {
  local IFS=.
  local a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

cidr_to_range() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"
  local ip_int
  local mask_int
  local range_start
  local range_end

  ip_int="$(ip_to_int "${ip}")"
  mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
  range_start=$(( ip_int & mask_int ))
  range_end=$(( range_start | (0xFFFFFFFF ^ mask_int) ))

  echo "${range_start} ${range_end}"
}

create_vm_subnet_with_auto_cidr() {
  local target_prefix="$1"
  local subnet_prefix_len="$2"
  local vnet_ip="${target_prefix%/*}"
  local vnet_mask="${target_prefix#*/}"

  local vnet_ip_int
  local mask_int
  local vnet_start
  local vnet_end
  local block_size
  local existing_subnets
  local subnet_cidr
  local subnet_range_start
  local subnet_range_end
  local gap_start
  local gap_end
  local chosen_start=""
  local aligned_start
  local line

  vnet_ip_int="$(ip_to_int "${vnet_ip}")"
  mask_int=$(( (0xFFFFFFFF << (32 - vnet_mask)) & 0xFFFFFFFF ))
  vnet_start=$(( vnet_ip_int & mask_int ))
  vnet_end=$(( vnet_start | (0xFFFFFFFF ^ mask_int) ))
  block_size=$(( 1 << (32 - subnet_prefix_len) ))

  existing_subnets="$(az network vnet subnet list --resource-group "${TARGET_VNET_RESOURCE_GROUP}" --vnet-name "${TARGET_VNET_NAME}" --query "[].addressPrefix" -o tsv | tr -d '\r')"

  gap_start="${vnet_start}"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    read -r subnet_range_start subnet_range_end <<<"${line}"
    gap_end=$(( subnet_range_start - 1 ))

    if (( gap_end >= gap_start )); then
      aligned_start=$(( ((gap_end - block_size + 1) / block_size) * block_size ))
      if (( aligned_start >= gap_start && aligned_start + block_size - 1 <= gap_end )); then
        chosen_start="${aligned_start}"
      fi
    fi

    next_gap_start=$(( subnet_range_end + 1 ))
    if (( next_gap_start > gap_start )); then
      gap_start="${next_gap_start}"
    fi
  done < <(
    while IFS= read -r subnet_cidr; do
      [[ -z "${subnet_cidr}" ]] && continue
      cidr_to_range "${subnet_cidr}"
    done < <(printf '%s\n' "${existing_subnets}") | sort -n -k1,1
  )

  if (( gap_start <= vnet_end )); then
    gap_end="${vnet_end}"
    aligned_start=$(( ((gap_end - block_size + 1) / block_size) * block_size ))
    if (( aligned_start >= gap_start && aligned_start + block_size - 1 <= gap_end )); then
      chosen_start="${aligned_start}"
    fi
  fi

  if [[ -n "${chosen_start}" ]]; then
    echo "$(int_to_ip "${chosen_start}")/${subnet_prefix_len}"
    return 0
  fi

  return 1
}

SUBNET_ID=""
TARGET_VNET_NAME=""
TARGET_VNET_RESOURCE_GROUP=""

if [[ -n "${VNET_NAME}" ]]; then
  TARGET_VNET_NAME="${VNET_NAME}"
  if [[ -n "${VNET_RESOURCE_GROUP}" ]]; then
    TARGET_VNET_RESOURCE_GROUP="${VNET_RESOURCE_GROUP}"
  else
    TARGET_VNET_RESOURCE_GROUP="$(az network vnet list --query "[?name=='${VNET_NAME}'].resourceGroup | [0]" -o tsv 2>/dev/null || true)"
    if [[ -z "${TARGET_VNET_RESOURCE_GROUP}" ]]; then
      TARGET_VNET_RESOURCE_GROUP="${RESOURCE_GROUP}"
    fi
  fi

  if [[ -n "${SUBNET_NAME}" ]]; then
    SUBNET_ID="$(az network vnet subnet show --resource-group "${TARGET_VNET_RESOURCE_GROUP}" --vnet-name "${TARGET_VNET_NAME}" --name "${SUBNET_NAME}" --query id -o tsv 2>/dev/null || true)"
    if [[ -z "${SUBNET_ID}" ]]; then
      echo "Subnet ${SUBNET_NAME} in VNet ${TARGET_VNET_NAME} was not found." >&2
      exit 1
    fi
    echo "Using subnet: ${SUBNET_ID}"
  fi
else
  SHARED_VNET_NAME="$(discover_shared_vnet || true)"
  if [[ -n "${SHARED_VNET_NAME}" ]]; then
    TARGET_VNET_NAME="${SHARED_VNET_NAME}"
    TARGET_VNET_RESOURCE_GROUP="${RESOURCE_GROUP}"
    echo "Using shared demo VNet: ${TARGET_VNET_NAME}"
  else
    SUBNET_ID="$(discover_subnet_id || true)"
    if [[ -z "${SUBNET_ID}" ]]; then
      echo "Unable to auto-discover shared demo VNet or AKS VNet subnet from clusters in ${RESOURCE_GROUP}." >&2
      echo "Provide --vnet-name (and optionally --vnet-resource-group)." >&2
      exit 1
    fi
    echo "Using subnet: ${SUBNET_ID}"

    TARGET_VNET_NAME="$(echo "${SUBNET_ID}" | sed -n 's|.*/virtualNetworks/\([^/]*\)/subnets/.*|\1|p')"
    TARGET_VNET_RESOURCE_GROUP="$(echo "${SUBNET_ID}" | sed -n 's|.*/resourceGroups/\([^/]*\)/providers/.*|\1|p')"
  fi
fi

if [[ -z "${TARGET_VNET_NAME}" || -z "${TARGET_VNET_RESOURCE_GROUP}" ]]; then
  if [[ -n "${SUBNET_ID}" ]]; then
    TARGET_VNET_NAME="$(echo "${SUBNET_ID}" | sed -n 's|.*/virtualNetworks/\([^/]*\)/subnets/.*|\1|p')"
    TARGET_VNET_RESOURCE_GROUP="$(echo "${SUBNET_ID}" | sed -n 's|.*/resourceGroups/\([^/]*\)/providers/.*|\1|p')"
  fi
fi

if [[ -z "${TARGET_VNET_NAME}" || -z "${TARGET_VNET_RESOURCE_GROUP}" ]]; then
  echo "Unable to resolve target VNet details." >&2
  exit 1
fi

echo "Target VNet resource group: ${TARGET_VNET_RESOURCE_GROUP}"
echo "Target VNet name: ${TARGET_VNET_NAME}"

TARGET_VNET_PREFIX="$(az network vnet show --resource-group "${TARGET_VNET_RESOURCE_GROUP}" --name "${TARGET_VNET_NAME}" --query "addressSpace.addressPrefixes[0]" -o tsv)"
if [[ -z "${TARGET_VNET_PREFIX}" ]]; then
  echo "Unable to read address space for VNet ${TARGET_VNET_NAME}." >&2
  exit 1
fi

echo "Creating or updating dedicated NSG ${VM_SUBNET_NSG_NAME}..."
az network nsg create \
  --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
  --name "${VM_SUBNET_NSG_NAME}" \
  --location "${LOCATION}" \
  --output none

# Minimal outbound rules for package repos/GitHub plus DNS resolution.
az network nsg rule create \
  --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
  --nsg-name "${VM_SUBNET_NSG_NAME}" \
  --name Allow-HTTPS-Outbound \
  --priority 100 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes Internet \
  --destination-port-ranges 443 \
  --output none

az network nsg rule create \
  --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
  --nsg-name "${VM_SUBNET_NSG_NAME}" \
  --name Allow-HTTP-Outbound \
  --priority 110 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes Internet \
  --destination-port-ranges 80 \
  --output none

az network nsg rule create \
  --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
  --nsg-name "${VM_SUBNET_NSG_NAME}" \
  --name Allow-DNS-UDP-Outbound \
  --priority 120 \
  --direction Outbound \
  --access Allow \
  --protocol Udp \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes 168.63.129.16 \
  --destination-port-ranges 53 \
  --output none

az network nsg rule create \
  --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
  --nsg-name "${VM_SUBNET_NSG_NAME}" \
  --name Allow-DNS-TCP-Outbound \
  --priority 121 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes 168.63.129.16 \
  --destination-port-ranges 53 \
  --output none

echo "Ensuring dedicated subnet ${VM_SUBNET_NAME} exists and is attached to NSG ${VM_SUBNET_NSG_NAME}..."
if az network vnet subnet show --resource-group "${TARGET_VNET_RESOURCE_GROUP}" --vnet-name "${TARGET_VNET_NAME}" --name "${VM_SUBNET_NAME}" --query id -o tsv >/dev/null 2>&1; then
  az network vnet subnet update \
    --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
    --vnet-name "${TARGET_VNET_NAME}" \
    --name "${VM_SUBNET_NAME}" \
    --network-security-group "${VM_SUBNET_NSG_NAME}" \
    --output none
else
  if [[ "${VM_SUBNET_PREFIX_EXPLICIT}" == "1" ]]; then
    az network vnet subnet create \
      --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
      --vnet-name "${TARGET_VNET_NAME}" \
      --name "${VM_SUBNET_NAME}" \
      --address-prefixes "${VM_SUBNET_PREFIX}" \
      --network-security-group "${VM_SUBNET_NSG_NAME}" \
      --output none
    echo "Created VM subnet using explicit CIDR: ${VM_SUBNET_PREFIX}"
  else
    if [[ "${VM_SUBNET_SIZE}" == "8" ]]; then
      AUTO_PREFIX_LEN="29"
    else
      AUTO_PREFIX_LEN="28"
    fi

    VM_SUBNET_PREFIX="$(create_vm_subnet_with_auto_cidr "${TARGET_VNET_PREFIX}" "${AUTO_PREFIX_LEN}")"
    if [[ -z "${VM_SUBNET_PREFIX}" ]]; then
      echo "Unable to auto-create a non-overlapping /${AUTO_PREFIX_LEN} subnet in VNet ${TARGET_VNET_NAME}." >&2
      echo "Use --vm-subnet-prefix with an explicit free CIDR inside ${TARGET_VNET_PREFIX}." >&2
      exit 1
    fi
    az network vnet subnet create \
      --resource-group "${TARGET_VNET_RESOURCE_GROUP}" \
      --vnet-name "${TARGET_VNET_NAME}" \
      --name "${VM_SUBNET_NAME}" \
      --address-prefixes "${VM_SUBNET_PREFIX}" \
      --network-security-group "${VM_SUBNET_NSG_NAME}" \
      --output none
    echo "Created VM subnet using auto-selected CIDR: ${VM_SUBNET_PREFIX}"
  fi
fi

VM_SUBNET_ID="$(az network vnet subnet show --resource-group "${TARGET_VNET_RESOURCE_GROUP}" --vnet-name "${TARGET_VNET_NAME}" --name "${VM_SUBNET_NAME}" --query id -o tsv)"

echo "Using dedicated VM subnet: ${VM_SUBNET_ID}"

echo "Creating Ubuntu VM ${VM_NAME} (no public IP, Bastion-friendly)..."
# In Git Bash/MSYS, disable automatic path conversion so /subscriptions/... stays intact.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az vm create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${VM_NAME}" \
  --location "${LOCATION}" \
  --image Ubuntu2204 \
  --size "${VM_SIZE}" \
  --admin-username "${ADMIN_USERNAME}" \
  --admin-password "${ADMIN_PASSWORD}" \
  --authentication-type password \
  --subnet "${VM_SUBNET_ID}" \
  --public-ip-address "" \
  --nsg "" \
  --output table

VM_ID="$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${VM_NAME}" --query id -o tsv)"
VM_PRIVATE_IP="$(az vm show --show-details --resource-group "${RESOURCE_GROUP}" --name "${VM_NAME}" --query privateIps -o tsv)"

echo
echo "VM created successfully"
echo "VM name: ${VM_NAME}"
echo "VM private IP: ${VM_PRIVATE_IP}"
echo "VM resource ID: ${VM_ID}"
echo "VM subnet: ${VM_SUBNET_ID}"
echo "VM subnet NSG: ${VM_SUBNET_NSG_NAME}"
echo
echo "Next steps:"
echo "1) Login through Bastion to VM ${VM_NAME}."
echo "2) Run install-az-cli-ubuntu.sh on the VM to install Azure CLI and kubectl."
echo "3) Run az login on VM and execute audit-managed-nginx-private-aks.sh."
