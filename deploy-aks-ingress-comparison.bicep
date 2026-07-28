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

var dnsPrefixBase = take(replace(toLower(namePrefix), '-', ''), 8)
var dnsPrefixSuffix = uniqueString(resourceGroup().id)
var dnsPrefixes = {
  publicManaged: 'aks${dnsPrefixBase}pub${dnsPrefixSuffix}'
  privateManagedOnPublic: 'aks${dnsPrefixBase}pvt${dnsPrefixSuffix}'
  publicNoNginx: 'aks${dnsPrefixBase}non${dnsPrefixSuffix}'
  privateManaged: 'aks${dnsPrefixBase}prv${dnsPrefixSuffix}'
  privateNoNginx: 'aks${dnsPrefixBase}pnn${dnsPrefixSuffix}'
}
var network = {
  vnetName: '${normalizedPrefix}vnet-aks-demo'
  addressPrefix: '10.240.0.0/16'
  subnets: {
    publicManaged: {
      name: 'snet-akspublicnginx'
      prefix: '10.240.0.0/20'
    }
    privateManagedOnPublic: {
      name: 'snet-akspvtnginx'
      prefix: '10.240.16.0/20'
    }
    publicNoNginx: {
      name: 'snet-aksnonginx'
      prefix: '10.240.32.0/20'
    }
    privateManaged: {
      name: 'snet-akspvtnginxpriv'
      prefix: '10.240.48.0/20'
    }
    privateNoNginx: {
      name: 'snet-akspvtnon-nginx'
      prefix: '10.240.64.0/20'
    }
    auditVm: {
      name: 'snet-vm-akspvt-audit'
      prefix: '10.240.80.0/24'
    }
  }
}

resource sharedVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: network.vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        network.addressPrefix
      ]
    }
    subnets: [
      {
        name: network.subnets.publicManaged.name
        properties: {
          addressPrefix: network.subnets.publicManaged.prefix
        }
      }
      {
        name: network.subnets.privateManagedOnPublic.name
        properties: {
          addressPrefix: network.subnets.privateManagedOnPublic.prefix
        }
      }
      {
        name: network.subnets.publicNoNginx.name
        properties: {
          addressPrefix: network.subnets.publicNoNginx.prefix
        }
      }
      {
        name: network.subnets.privateManaged.name
        properties: {
          addressPrefix: network.subnets.privateManaged.prefix
        }
      }
      {
        name: network.subnets.privateNoNginx.name
        properties: {
          addressPrefix: network.subnets.privateNoNginx.prefix
        }
      }
      {
        name: network.subnets.auditVm.name
        properties: {
          addressPrefix: network.subnets.auditVm.prefix
        }
      }
    ]
  }
}

resource aksPublicManagedSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.publicManaged.name
}

resource aksPrivateManagedOnPublicSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.privateManagedOnPublic.name
}

resource aksPublicNoNginxSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.publicNoNginx.name
}

resource aksPrivateManagedSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.privateManaged.name
}

resource aksPrivateNoNginxSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.privateNoNginx.name
}

resource auditVmSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: sharedVnet
  name: network.subnets.auditVm.name
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

resource aksPublicManaged 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusters.publicManaged
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefixes.publicManaged
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksPublicManagedSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: false
      }
    }
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
  }
}

resource aksPrivateManagedOnPublic 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusters.privateManagedOnPublic
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefixes.privateManagedOnPublic
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    apiServerAccessProfile: {
      enablePrivateCluster: false
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksPrivateManagedOnPublicSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
  }
}

resource aksPublicNoNginx 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusters.publicNoNginx
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefixes.publicNoNginx
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksPublicNoNginxSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
  }
}

resource aksPrivateManaged 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusters.privateManaged
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefixes.privateManaged
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    apiServerAccessProfile: {
      enablePrivateCluster: true
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksPrivateManagedSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
  }
}

resource aksPrivateNoNginx 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusters.privateNoNginx
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefixes.privateNoNginx
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    apiServerAccessProfile: {
      enablePrivateCluster: true
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksPrivateNoNginxSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
  }
}

resource aksPublicManagedUserPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aksPublicManaged
  name: 'userpool'
  properties: {
    mode: 'User'
    count: nodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksPublicManagedSubnet.id
  }
}

resource aksPrivateManagedOnPublicUserPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aksPrivateManagedOnPublic
  name: 'userpool'
  properties: {
    mode: 'User'
    count: nodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksPrivateManagedOnPublicSubnet.id
  }
}

resource aksPublicNoNginxUserPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aksPublicNoNginx
  name: 'userpool'
  properties: {
    mode: 'User'
    count: nodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksPublicNoNginxSubnet.id
  }
}

resource aksPrivateManagedUserPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aksPrivateManaged
  name: 'userpool'
  properties: {
    mode: 'User'
    count: nodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksPrivateManagedSubnet.id
  }
}

resource aksPrivateNoNginxUserPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aksPrivateNoNginx
  name: 'userpool'
  properties: {
    mode: 'User'
    count: nodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksPrivateNoNginxSubnet.id
  }
}

output createdClusters object = clusters
output sharedVnetName string = sharedVnet.name
output sharedSubnetNames object = {
  publicManaged: aksPublicManagedSubnet.name
  privateManagedOnPublic: aksPrivateManagedOnPublicSubnet.name
  publicNoNginx: aksPublicNoNginxSubnet.name
  privateManaged: aksPrivateManagedSubnet.name
  privateNoNginx: aksPrivateNoNginxSubnet.name
  auditVm: auditVmSubnet.name
}
output userAssignedIdentityName string = deploymentIdentity.name
output userAssignedIdentityPrincipalId string = deploymentIdentity.properties.principalId
