#!/usr/bin/env bash
set -euo pipefail

# Installs Azure CLI + kubectl on Ubuntu VM for AKS audit scripts.

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to run this installer." >&2
  exit 1
fi

echo "Updating apt package index..."
sudo apt-get update -y

echo "Installing prerequisite packages..."
sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg jq unzip

echo "Configuring Microsoft package repository..."
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null

AZ_REPO="$(lsb_release -cs)"
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli ${AZ_REPO} main" | sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null

echo "Installing Azure CLI..."
sudo apt-get update -y
sudo apt-get install -y azure-cli

echo "Installing kubectl..."
sudo az aks install-cli --install-location /usr/local/bin/kubectl

echo
echo "Installation complete"
echo "Azure CLI version:"
az version --output table || true
echo
echo "kubectl client version:"
kubectl version --client || true
echo
echo "Next steps:"
echo "1) az login"
echo "2) az account set --subscription <subscription-id>"
echo "3) chmod +x audit-managed-nginx-private-aks.sh"
echo "4) ./audit-managed-nginx-private-aks.sh"
