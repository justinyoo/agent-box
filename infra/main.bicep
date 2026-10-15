targetScope = 'subscription'

@description('azd environment name. Use a distinct name for a new environment.')
@minLength(1)
@maxLength(24)
param environmentName string = 'dev'

@description('Azure region. Size, image, zone, and policy compatibility must be checked when changing it.')
@minLength(1)
param location string

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
