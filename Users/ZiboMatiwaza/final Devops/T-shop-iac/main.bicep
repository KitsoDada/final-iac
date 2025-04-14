@description('Prefix for naming Azure resources')
param prefix string = 'tshop'

@description('The name of the Managed Cluster resource.')
param clusterName string = '${prefix}-aks-cluster'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('Optional DNS prefix to use with hosted Kubernetes API server FQDN.')
param dnsPrefix string = '${prefix}-aks'

@description('Disk size (in GB) for agent pool nodes (0 uses default).')
@minValue(0)
@maxValue(1023)
param osDiskSizeGB int = 0

@description('Node count for AKS.')
@minValue(1)
@maxValue(50)
param agentCount int = 3

@description('Virtual Machine size for agents.')
param agentVMSize string = 'Standard_B2s'

@description('Linux admin username.')
param linuxAdminUsername string = 'aksadmin'

@description('SSH RSA public key.')
@secure()
param sshRSAPublicKey string

@description('VNet name.')
param vnetName string = '${prefix}-vnet'

@description('Public subnet name.')
param publicSubnetName string = '${prefix}-subnet-public'

@description('Private subnet name.')
param privateSubnetName string = '${prefix}-subnet-private'

@description('Container Registry name.')
param acrName string = '${prefix}acr${uniqueString(resourceGroup().id)}'

@description('Application Gateway name.')
param appGatewayName string = '${prefix}-appgw'

@description('App Service Plan name.')
param appServicePlanName string = '${prefix}-asp'

@description('Web App name.')
param webAppName string = '${prefix}-webapp${uniqueString(resourceGroup().id)}'

@description('Container image to deploy.')
param containerImage string = 'tshop-service:latest'

@description('Client ID for AKS service principal.')
@secure()
param aksServicePrincipalClientId string

// Tags
var commonTags = {
  environment: 'dev'
  owner: 'yourname'
  project: 'devops-assessment'
}

// Virtual Network with subnets
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: publicSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        name: privateSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
  tags: commonTags
}

// Public IP for Application Gateway
resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${appGatewayName}-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
  tags: commonTags
}

// Application Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2023-05-01' = {
  name: appGatewayName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, publicSubnetName)
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontendConfig'
        properties: {
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'httpPort'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'defaultPool'
        properties: {}
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'defaultSettings'
        properties: {
          port: 80
          protocol: 'Http'
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGatewayName, 'frontendConfig')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGatewayName, 'httpPort')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'defaultRule'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGatewayName, 'listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGatewayName, 'defaultPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGatewayName, 'defaultSettings')
          }
        }
      }
    ]
  }
  tags: commonTags
}

// AKS Cluster
resource aks 'Microsoft.ContainerService/managedClusters@2023-05-02-preview' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: agentCount
        vmSize: agentVMSize
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, privateSubnetName)
      }
    ]
    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      serviceCidr: '10.2.0.0/16'
      dnsServiceIP: '10.2.0.10'
      loadBalancerSku: 'standard'
    }
    addonProfiles: {
      httpApplicationRouting: {
        enabled: false
      }
      omsAgent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: ''
        }
      }
    }
  }
  tags: commonTags
}

// Grant AKS permissions to ACR
resource acrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, aks.id, 'acrpull')
  properties: {
    principalId: aks.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
  }
}

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'P1v2'
    tier: 'PremiumV2'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
  tags: commonTags
}

// Web App for Containers
resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acr.properties.loginServer}/${containerImage}'
      alwaysOn: true
    }
    httpsOnly: true
  }
  identity: {
    type: 'SystemAssigned'
  }
  tags: commonTags
}
