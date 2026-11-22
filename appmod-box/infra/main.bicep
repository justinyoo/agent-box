targetScope = 'subscription'

@minLength(1)
@maxLength(32)
param environmentName string

@allowed([
  'australiacentral'
  'australiaeast'
  'australiasoutheast'
  'brazilsouth'
  'canadacentral'
  'canadaeast'
  'centralindia'
  'centralus'
  'eastasia'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'japanwest'
  'koreacentral'
  'koreasouth'
  'mexicocentral'
  'northcentralus'
  'northeurope'
  'norwayeast'
  'southafricanorth'
  'southindia'
  'southeastasia'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'uaenorth'
  'uksouth'
  'ukwest'
  'westcentralus'
  'westeurope'
  'westus'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

param scriptPayloadPart1 string = ''
param scriptPayloadPart2 string = ''
param scriptPayloadPart3 string = ''

@minLength(1)
@maxLength(20)
param adminUsername string = 'appmoduser'

@secure()
@minLength(12)
@maxLength(123)
@description('Local administrator password. Include at least three of uppercase letters, lowercase letters, digits and special characters.')
param adminPassword string

@allowed([
  true
])
@description('Set to true only after confirming that you are eligible to run Windows 11 client licenses on Azure.')
param confirmWindowsClientLicense bool

@allowed([
  'Standard_D4s_v5'
  'Standard_D8s_v5'
  'Standard_D8ds_v5'
  'Standard_D16s_v5'
])
param vmSize string = 'Standard_D8s_v5'

@minLength(3)
@maxLength(4)
param osDiskSizeGB string = '256'

@allowed([
  'true'
  'false'
])
param autoShutdownEnabled string = 'true'

@minLength(4)
@maxLength(4)
@description('Daily auto-shutdown (deallocation) time in Korea Standard Time, in 24-hour HHmm format.')
param autoShutdownTime string = '0000'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  workload: 'windows-app-modernization'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module workstation 'modules/workstation.bicep' = {
  name: 'workstation'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    adminUsername: adminUsername
    adminPassword: adminPassword
    confirmWindowsClientLicense: confirmWindowsClientLicense
    vmSize: vmSize
    osDiskSizeGB: int(osDiskSizeGB)
    autoShutdownEnabled: bool(autoShutdownEnabled)
    autoShutdownTime: autoShutdownTime
  }
}

module userScripts 'modules/user-scripts.bicep' = {
  name: 'user-scripts'
  scope: rg
  params: {
    location: location
    vmName: workstation.outputs.vmName
    adminUsername: adminUsername
    tags: tags
    scriptPayload: '${scriptPayloadPart1}${scriptPayloadPart2}${scriptPayloadPart3}'
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_VM_NAME string = workstation.outputs.vmName
output AZURE_VM_ID string = workstation.outputs.vmId
output AZURE_VM_ADMIN_USERNAME string = adminUsername
output AZURE_BASTION_NAME string = workstation.outputs.bastionName
output AZURE_SCRIPT_DELIVERY string = userScripts.outputs.runCommandName
