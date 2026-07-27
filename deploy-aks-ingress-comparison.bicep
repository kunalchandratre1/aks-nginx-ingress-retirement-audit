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
    kubernetesVersion: empty(kubernetesVersion) ? json('null') : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
    addonProfiles: {
      'azureKeyvaultSecretsProvider': {
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
    kubernetesVersion: empty(kubernetesVersion) ? json('null') : kubernetesVersion
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
    kubernetesVersion: empty(kubernetesVersion) ? json('null') : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
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
    kubernetesVersion: empty(kubernetesVersion) ? json('null') : kubernetesVersion
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
    kubernetesVersion: empty(kubernetesVersion) ? json('null') : kubernetesVersion
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
  }
}

output createdClusters object = clusters
output userAssignedIdentityName string = deploymentIdentity.name
output userAssignedIdentityPrincipalId string = deploymentIdentity.properties.principalId
