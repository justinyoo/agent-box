targetScope = 'subscription'

@minLength(1)
@maxLength(32)
param environmentName string

@description('VM region. The preprovision hook checks Bastion Developer, VM image, size, and zone availability.')
@allowed([
  'australiasoutheast'
  'brazilsouth'
  'centralus'
  'eastasia'
  'eastus2'
  'germanywestcentral'
  'japanwest'
  'koreacentral'
  'koreasouth'
  'northcentralus'
  'swedencentral'
  'uksouth'
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
param adminUsername string = 'agentboxuser'

@secure()
@minLength(12)
@maxLength(123)
param adminPassword string

@allowed([
  true
])
@description('Set to true only after confirming that you are eligible to run Windows 11 client licenses on Azure.')
param confirmWindowsClientLicense bool

@description('Region for MAI-Image-2.7 and the MAI Speech models.')
@allowed([
  'eastus'
  'swedencentral'
  'westeurope'
  'westus'
])
@metadata({
  azd: {
    type: 'location'
  }
})
@minLength(1)
@maxLength(42)
param maiFoundryRegion string

@minLength(1)
@maxLength(4)
param maiImageCapacity string = '1'

@minLength(1)
param maiImageDeploymentName string = 'mai-image-2.7'

@minLength(1)
param maiVoiceModel string = 'MAI-Voice-2.1'

@minLength(1)
param maiTranscribeModel string = 'MAI-Transcribe-2'

@maxLength(50)
param vmName string = ''

@maxLength(15)
param computerName string = ''

@minLength(1)
param vmSize string = 'Standard_D64ds_v7'
@allowed([
  ''
  '1'
  '2'
  '3'
  '4'
])
param zone string = ''
@minLength(1)
param imagePublisher string = 'microsoftwindowsdesktop'
@minLength(1)
param imageOffer string = 'windows-11'
@minLength(1)
param imageSku string = 'win11-26h2-ent'
@minLength(1)
param imageVersion string = 'latest'

@minLength(1)
@maxLength(4)
param osDiskSizeGb string = '127'

@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param osDiskType string = 'Premium_LRS'
@allowed([
  'NVMe'
  'SCSI'
])
param diskControllerType string = 'NVMe'
@allowed([
  'true'
  'false'
])
param acceleratedNetworking string = 'true'
@minLength(1)
@maxLength(18)
param vnetAddressPrefix string = '172.16.0.0/16'
@minLength(1)
@maxLength(18)
param subnetAddressPrefix string = '172.16.0.0/24'
@allowed([
  'true'
  'false'
])
param autoShutdownEnabled string = 'true'
param tags object = {}

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var resourceTags = union(tags, {
  'azd-env-name': environmentName
})
var resolvedVmName = empty(vmName)
  ? 'vm-${resourceToken}'
  : vmName
var resolvedComputerName = empty(computerName)
  ? take('w11-${resourceToken}', 15)
  : computerName
var resourceGroupName = 'rg-${environmentName}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: resourceTags
}

module workstation './modules/workstation.bicep' = {
  name: 'agent-box-workstation'
  scope: resourceGroup
  params: {
    location: location
    resourceToken: resourceToken
    vmName: resolvedVmName
    computerName: resolvedComputerName
    vmSize: vmSize
    zone: zone
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    adminUsername: adminUsername
    adminPassword: adminPassword
    confirmWindowsClientLicense: confirmWindowsClientLicense
    osDiskSizeGb: int(osDiskSizeGb)
    osDiskType: osDiskType
    diskControllerType: diskControllerType
    acceleratedNetworking: bool(acceleratedNetworking)
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    autoShutdownEnabled: bool(autoShutdownEnabled)
    tags: resourceTags
  }
}

module userScripts './modules/user-scripts.bicep' = {
  name: 'agent-box-user-scripts'
  scope: resourceGroup
  params: {
    location: location
    vmName: workstation.outputs.vmName
    adminUsername: adminUsername
    tags: resourceTags
    scriptPayload: '${scriptPayloadPart1}${scriptPayloadPart2}${scriptPayloadPart3}'
  }
}

module foundry './modules/foundry.bicep' = {
  name: 'agent-box-foundry'
  scope: resourceGroup
  params: {
    name: 'cogsvc-${resourceToken}-${maiFoundryRegion}'
    projectName: 'proj-${resourceToken}-${maiFoundryRegion}'
    location: maiFoundryRegion
    imageDeploymentName: maiImageDeploymentName
    capacity: int(maiImageCapacity)
    tags: resourceTags
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_VM_NAME string = workstation.outputs.vmName
output AZURE_VM_ID string = workstation.outputs.vmId
output AZURE_VM_ADMIN_USERNAME string = adminUsername
output AZURE_BASTION_NAME string = workstation.outputs.bastionName
output AZURE_SCRIPT_DELIVERY string = userScripts.outputs.runCommandName
output FOUNDRY_ACCOUNT_NAME string = foundry.outputs.accountName
output FOUNDRY_ACCOUNT_ID string = foundry.outputs.accountId
output FOUNDRY_PROJECT_NAME string = foundry.outputs.projectName
output FOUNDRY_PROJECT_ENDPOINT string = foundry.outputs.projectEndpoint
output MAI_IMAGE_ENDPOINT string = foundry.outputs.imageEndpoint
output MAI_IMAGE_DEPLOYMENT_NAME string = foundry.outputs.imageDeploymentName
output AZURE_SPEECH_ENDPOINT string = foundry.outputs.speechEndpoint
output AZURE_SPEECH_REGION string = maiFoundryRegion
output MAI_VOICE_MODEL string = maiVoiceModel
output MAI_TRANSCRIBE_MODEL string = maiTranscribeModel
