targetScope = 'subscription'

@description('azd environment name. Use a distinct name for a new environment.')
@minLength(1)
@maxLength(24)
param environmentName string = 'dev'

@description('VM and resource group region, independent of the model regions. Check size, image, zone, quota, and policy compatibility.')
@metadata({
  azd: {
    type: 'location'
  }
})
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'southcentralus'
  'uksouth'
  'westus2'
  'westus3'
])
param location string

@description('Required GPT-Image 2.5 Sunburst GlobalStandard deployment region. Models in the same region share a Foundry account and project.')
@metadata({
  azd: {
    type: 'location'
  }
})
@allowed([
  'eastus2'
  'polandcentral'
  'swedencentral'
  'uaenorth'
  'westus3'
])
param gptImage25Region string

@description('Required GPT-6 Astra GlobalStandard deployment region, independent of the VM and other models.')
@metadata({
  azd: {
    type: 'location'
  }
})
@allowed([
  'australiaeast'
  'brazilsouth'
  'canadacentral'
  'canadaeast'
  'centralus'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'norwayeast'
  'polandcentral'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'southindia'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'switzerlandwest'
  'uaenorth'
  'uksouth'
  'westeurope'
  'westus'
  'westus3'
])
param gpt6AstraRegion string

@description('Required Azure-hosted Claude Opus 5.5 GlobalStandard deployment region, independent of the VM and other models.')
@metadata({
  azd: {
    type: 'location'
  }
})
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'swedencentral'
  'westcentralus'
  'westus'
  'westus3'
])
param claudeOpus55Region string

@description('GPT-Image 2.5 deployment capacity units as decimal text. Requires available model quota; units differ between models.')
@minLength(1)
@maxLength(4)
param gptImage25Capacity string = '3'

@description('GPT-6 Astra deployment capacity units as decimal text. Requires available model quota.')
@minLength(1)
@maxLength(8)
param gpt6AstraCapacity string = '10'

@description('Claude Opus 5.5 deployment capacity units as decimal text. Requires available model quota.')
@minLength(1)
@maxLength(7)
param claudeOpus55Capacity string = '10'

@description('Legal organization name for Claude Marketplace attestation. Provisioning accepts the offer terms on your behalf; review README.md first.')
@minLength(1)
param claudeOrganizationName string

@description('Two-letter ISO country code for the organization using Claude. Supplied to Azure Marketplace.')
@minLength(2)
@maxLength(2)
param claudeCountryCode string

@description('Organization industry for Claude Marketplace attestation. Must accurately describe the organization using the model.')
@allowed([
  'technology'
  'finance'
  'healthcare'
  'education'
  'retail'
  'manufacturing'
  'government'
  'media'
  'other'
])
param claudeIndustry string

@description('Resource name prefix. Use letters, digits, and hyphens.')
@minLength(1)
@maxLength(12)
param namePrefix string = 'agentbox'

@description('VM resource name; companion resource names are derived from it.')
@minLength(1)
@maxLength(50)
param vmName string = 'vm-${namePrefix}-${environmentName}-${take(uniqueString(subscription().id, environmentName, namePrefix), 6)}'

@description('Windows computer name, at most 15 characters. The default is deterministic and environment-specific.')
@minLength(1)
@maxLength(15)
param computerName string = 'ab-${take(uniqueString(subscription().id, environmentName, namePrefix), 12)}'

@description('VM size. The baseline has 64 vCPUs and 256 GiB RAM and is relatively expensive.')
@minLength(1)
param vmSize string = 'Standard_D64ds_v7'

@description('Availability zone, or an explicit empty string for a regional VM.')
@allowed(['', '1', '2', '3'])
param zone string = '1'

@minLength(1)
param imagePublisher string = 'microsoftwindowsdesktop'

@minLength(1)
param imageOffer string = 'windows-11'

@description('Use a supported single-session Windows 11 image, not an AVD multi-session image.')
@minLength(1)
param imageSku string = 'win11-26h2-ent'

@description('Use latest, or a published concrete image version for reproducibility.')
@minLength(1)
param imageVersion string = 'latest'

@description('Initial Azure-provisioned local administrator. It must differ from enrollmentAdminUsername.')
@minLength(1)
@maxLength(20)
param adminUsername string = 'azureuser'

@description('Normal local administrator used for joining the Intune enrollment tenant and running first-sign-in tools.')
@minLength(1)
@maxLength(20)
param enrollmentAdminUsername string = 'enrolleduser'

@description('Required initial password for both accounts. Never place an actual password in a committed file.')
@secure()
@minLength(12)
@maxLength(123)
param adminPassword string

@description('OS disk GiB as decimal text. Strict conversion avoids azd silently discarding invalid numeric environment values.')
@minLength(1)
@maxLength(4)
param osDiskSizeGb string = '127'

@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS'])
param osDiskType string = 'Premium_LRS'

@description('Must be supported by both the VM size and the Generation 2 image.')
@allowed(['NVMe', 'SCSI'])
param diskControllerType string = 'NVMe'

@description('Text true/false for strict azd environment validation; converted to a boolean in the resource module.')
@allowed(['true', 'false'])
param acceleratedNetworking string = 'true'

@description('IPv4 VNet CIDR.')
@minLength(1)
@maxLength(18)
param vnetAddressPrefix string = '172.16.0.0/16'

@description('IPv4 subnet CIDR contained within the VNet.')
@minLength(1)
@maxLength(18)
param subnetAddressPrefix string = '172.16.0.0/24'

@description('Current trusted source IPv4 address/CIDR for TCP 3389. Combined with additionalRdpSources.')
@maxLength(18)
param allowedRdpSource string = ''

@description('JSON array text of additional trusted IPv4 addresses/CIDRs for TCP 3389. Combined with allowedRdpSource; both empty means no public RDP allow rule.')
param additionalRdpSources string = '[]'

@description('Python major.minor version installed through uv at the secondary administrator first sign-in.')
@minLength(3)
@maxLength(6)
param pythonVersion string = '3.14'

@description('Additional resource tags. The azd environment identity tag cannot be overridden.')
param tags object = {}

var resourceGroupName = 'rg-${namePrefix}-${environmentName}'
var rdpSources = union(empty(allowedRdpSource) ? [] : [allowedRdpSource], json(additionalRdpSources))
var resourceTags = union(tags, {
  'azd-env-name': environmentName
})
var modelDeployments = [
  {
    region: gptImage25Region
    deployment: {
      name: 'gpt-image-2.5-sunburst'
      model: {
        format: 'OpenAI'
        name: 'gpt-image-2.5-sunburst'
        version: '2026-09-08'
      }
      capacity: int(gptImage25Capacity)
    }
  }
  {
    region: gpt6AstraRegion
    deployment: {
      name: 'gpt-6-astra'
      model: {
        format: 'OpenAI'
        name: 'gpt-6-astra'
        version: '2026-09-03'
      }
      capacity: int(gpt6AstraCapacity)
    }
  }
  {
    region: claudeOpus55Region
    deployment: {
      name: 'claude-opus-5-5'
      model: {
        format: 'Anthropic'
        name: 'claude-opus-5-5'
        version: '2'
      }
      capacity: int(claudeOpus55Capacity)
      modelProviderData: {
        organizationName: claudeOrganizationName
        countryCode: toUpper(claudeCountryCode)
        industry: claudeIndustry
      }
    }
  }
]
var foundryRegions = union([gptImage25Region], [gpt6AstraRegion], [claudeOpus55Region])
var foundryConfigurations = [for region in foundryRegions: {
  name: 'ai-${uniqueString(subscription().id, resourceGroupName, region)}'
  location: region
  deployments: map(filter(modelDeployments, model => model.region == region), model => model.deployment)
}]

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: resourceTags
}

module resources './resources.bicep' = {
  name: 'agent-box-resources'
  scope: resourceGroup
  params: {
    location: location
    vmName: vmName
    computerName: computerName
    vmSize: vmSize
    zone: zone
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    adminUsername: adminUsername
    enrollmentAdminUsername: enrollmentAdminUsername
    adminPassword: adminPassword
    osDiskSizeGb: int(osDiskSizeGb)
    osDiskType: osDiskType
    diskControllerType: diskControllerType
    acceleratedNetworking: bool(acceleratedNetworking)
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    allowedRdpSources: rdpSources
    pythonVersion: pythonVersion
    tags: resourceTags
  }
}

module foundry './foundry.bicep' = [for configuration in foundryConfigurations: {
  name: 'agent-box-foundry-${configuration.location}'
  scope: resourceGroup
  params: {
    name: configuration.name
    location: configuration.location
    deployments: configuration.deployments
    tags: resourceTags
  }
}]

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output VM_NAME string = resources.outputs.vmName
output VM_RESOURCE_ID string = resources.outputs.vmId
output VM_COMPUTER_NAME string = resources.outputs.computerName
output VM_PUBLIC_IP string = resources.outputs.publicIpAddress
output VM_RDP_ENDPOINT string = resources.outputs.rdpEndpoint
output VM_RDP_ENABLED bool = !empty(rdpSources)
output ENROLLMENT_SCRIPT_PATH string = resources.outputs.enrollmentScriptPath
output DEV_TOOLS_SCRIPT_PATH string = resources.outputs.devToolsScriptPath
output DEV_TOOLS_TASK_PATH string = resources.outputs.devToolsTaskPath
output FOUNDRY_RESOURCES array = [for (region, index) in foundryRegions: {
  region: region
  accountName: foundry[index].outputs.accountName
  accountId: foundry[index].outputs.accountId
  projectName: foundry[index].outputs.projectName
  projectId: foundry[index].outputs.projectId
  projectEndpoint: foundry[index].outputs.projectEndpoint
}]
output GPT_IMAGE_25_BASE_URL string = foundry[indexOf(foundryRegions, gptImage25Region)].outputs.openAiBaseUrl
output GPT_IMAGE_25_DEPLOYMENT_NAME string = modelDeployments[0].deployment.name
output GPT_6_ASTRA_BASE_URL string = foundry[indexOf(foundryRegions, gpt6AstraRegion)].outputs.openAiBaseUrl
output GPT_6_ASTRA_DEPLOYMENT_NAME string = modelDeployments[1].deployment.name
output CLAUDE_OPUS_55_BASE_URL string = foundry[indexOf(foundryRegions, claudeOpus55Region)].outputs.anthropicBaseUrl
output CLAUDE_OPUS_55_DEPLOYMENT_NAME string = modelDeployments[2].deployment.name
