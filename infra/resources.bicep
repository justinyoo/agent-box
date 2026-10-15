targetScope = 'resourceGroup'

param location string
param vmName string
param computerName string
param vmSize string
param zone string
param imagePublisher string
param imageOffer string
param imageSku string
param imageVersion string
param adminUsername string
param enrollmentAdminUsername string

@secure()
param adminPassword string

@minValue(127)
@maxValue(4095)
param osDiskSizeGb int

param osDiskType string
param diskControllerType string
param acceleratedNetworking bool
param vnetAddressPrefix string
param subnetAddressPrefix string
param allowedRdpSource string
param pythonVersion string
param tags object

var localAdminScript = loadFileAsBase64('../scripts/New-LocalAdmin.ps1')
var initializationScript = loadFileAsBase64('../scripts/Initialize-Guest.ps1')
var enrollmentScript = loadFileAsBase64('../scripts/Start-IntuneEnrollment.ps1')
var devToolsScript = loadFileAsBase64('../scripts/Install-DevTools.ps1')
var stagingScript = loadTextContent('../scripts/Stage-GuestScripts.ps1')
var guestConfiguration = {
  initialAdminUsername: adminUsername
  enrollmentAdminUsername: enrollmentAdminUsername
  pythonVersion: pythonVersion
}
var guestConfigurationBase64 = base64(string(guestConfiguration))
var setupFingerprint = uniqueString(stagingScript, localAdminScript, initializationScript, enrollmentScript, devToolsScript, string(guestConfiguration))

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2025-09-01' = {
  name: '${vmName}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: empty(allowedRdpSource) ? [] : [
      {
        name: 'allow-rdp-from-trusted-source'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedRdpSource
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: '${vmName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'workstation'
        properties: {
          addressPrefix: subnetAddressPrefix
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2025-09-01' = {
  name: '${vmName}-ip'
  location: location
  tags: tags
  zones: empty(zone) ? [] : [zone]
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2025-09-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: acceleratedNetworking
    enableIPForwarding: false
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: '${virtualNetwork.id}/subnets/workstation'
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: vmName
  location: location
  tags: tags
  zones: empty(zone) ? [] : [zone]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    licenseType: 'Windows_Client'
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      diskControllerType: diskControllerType
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: '${vmName}-os'
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGb
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
      dataDisks: []
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
          enableHotpatching: false
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// source.script is delivered as a file, not as an oversized process command line.
resource stageGuestScripts 'Microsoft.Compute/virtualMachines/runCommands@2026-04-01' = {
  parent: virtualMachine
  name: 'stage-guest-scripts'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true
    source: {
      script: format('''
& {{
{0}
}} -Files @{{
  'New-LocalAdmin.ps1' = '{1}'
  'Initialize-Guest.ps1' = '{2}'
  'Start-IntuneEnrollment.ps1' = '{3}'
  'Install-DevTools.ps1' = '{4}'
}}
''', stagingScript, localAdminScript, initializationScript, enrollmentScript, devToolsScript)
    }
  }
}

resource configureGuest 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
  parent: virtualMachine
  name: 'configure-guest'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: setupFingerprint
    protectedSettings: {
      commandToExecute: 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference=\'Stop\'; $c=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${guestConfigurationBase64}\'))); $p=ConvertTo-SecureString ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(adminPassword)}\'))) -AsPlainText -Force; try { & (Join-Path $env:ProgramData \'AgentBox/Scripts/Initialize-Guest.ps1\') -InitialAdminUsername $c.initialAdminUsername -EnrollmentAdminUsername $c.enrollmentAdminUsername -PythonVersion $c.pythonVersion -Password $p } finally { $p.Dispose() }"'
    }
  }
  dependsOn: [stageGuestScripts]
}

output vmName string = virtualMachine.name
output vmId string = virtualMachine.id
output computerName string = computerName
output publicIpAddress string = publicIp.properties.ipAddress
output rdpEndpoint string = '${publicIp.properties.ipAddress}:3389'
output enrollmentScriptPath string = 'C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1'
output devToolsScriptPath string = 'C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1'
output devToolsTaskPath string = '\\AgentBox\\InstallDevTools'
