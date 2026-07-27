#!/usr/bin/env bash
set -euo pipefail

# Creates a Bastion-friendly Ubuntu VM for running private AKS audit scripts.
# Default behavior creates a VM without public IP in an existing VNet/subnet.

RESOURCE_GROUP="rg-aks-ingress-compare-aue"
LOCATION=""
VM_NAME="vm-akspvt-audit"
VNET_NAME="vnet-akspvtnginxpriv"
SUBNET_NAME="snet-akspvtnginxpriv"
VM_SIZE="Standard_B2s"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --resource-group <name>   Resource group name (default: ${RESOURCE_GROUP})
  --location <region>       Azure region. If omitted, uses resource group location.
  --vm-name <name>          VM name (default: ${VM_NAME})
  --vnet-name <name>        Existing VNet name (default: ${VNET_NAME})
  --subnet-name <name>      Existing subnet name (default: ${SUBNET_NAME})
  --vm-size <size>          VM size (default: ${VM_SIZE})
  --admin-username <user>   Admin username for Ubuntu VM
  --admin-password <pass>   Admin password for Ubuntu VM
  -h, --help                Show this help

Examples:
  $0 --admin-username azureuser
  $0 --resource-group rg-aks-ingress-compare-aue --admin-username azureuser
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

if [[ -z "${LOCATION}" ]]; then
  LOCATION="$(az group show --name "${RESOURCE_GROUP}" --query location -o tsv 2>/dev/null || true)"
fi

if [[ -z "${LOCATION}" ]]; then
  echo "Unable to determine location. Set --location explicitly or ensure resource group exists." >&2
  exit 1
fi

echo "Using resource group: ${RESOURCE_GROUP}"
echo "Using location: ${LOCATION}"
echo "Checking VNet and subnet..."

if ! az network vnet show --resource-group "${RESOURCE_GROUP}" --name "${VNET_NAME}" --query name -o tsv >/dev/null 2>&1; then
  echo "VNet ${VNET_NAME} not found in resource group ${RESOURCE_GROUP}." >&2
  exit 1
fi

if ! az network vnet subnet show --resource-group "${RESOURCE_GROUP}" --vnet-name "${VNET_NAME}" --name "${SUBNET_NAME}" --query name -o tsv >/dev/null 2>&1; then
  echo "Subnet ${SUBNET_NAME} not found in VNet ${VNET_NAME}." >&2
  exit 1
fi

echo "Creating Ubuntu VM ${VM_NAME} (no public IP, Bastion-friendly)..."
az vm create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${VM_NAME}" \
  --location "${LOCATION}" \
  --image Ubuntu2204 \
  --size "${VM_SIZE}" \
  --admin-username "${ADMIN_USERNAME}" \
  --admin-password "${ADMIN_PASSWORD}" \
  --authentication-type password \
  --vnet-name "${VNET_NAME}" \
  --subnet "${SUBNET_NAME}" \
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
echo
echo "Next steps:"
echo "1) Login through Bastion to VM ${VM_NAME}."
echo "2) Run install-az-cli-ubuntu.sh on the VM to install Azure CLI and kubectl."
echo "3) Run az login on VM and execute audit-managed-nginx-private-aks.sh."
