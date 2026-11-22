targetScope = 'resourceGroup'

param location string
param resourceToken string
param vmName string
param computerName string
param vmSize string
@minLength(1)
param zone string
param imagePublisher string
param imageOffer string
param imageSku string
param imageVersion string
param adminUsername string

@secure()
param adminPassword string

@allowed([
  true
])
param confirmWindowsClientLicense bool

@minValue(127)
@maxValue(4095)
param osDiskSizeGb int

param osDiskType string
param diskControllerType string
param acceleratedNetworking bool
param vnetAddressPrefix string
param subnetAddressPrefix string
param autoShutdownEnabled bool
param tags object

var subnetName = 'snet-workstation'
var timeZoneId = 'Korea Standard Time'

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: 'nsg-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: 'pip-nat-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2025-01-01' = {
  name: 'ng-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-01-01' = {
  name: 'vnet-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ]
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-01-01' = {
  name: 'bas-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Developer'
  }
  properties: {
    scaleUnits: 2
    ipConfigurations: []
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2025-01-01' = {
  name: 'nic-${resourceToken}'
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
            id: '${virtualNetwork.id}/subnets/${subnetName}'
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  tags: tags
  zones: [
    zone
  ]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    licenseType: confirmWindowsClientLicense ? 'Windows_Client' : null
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
        name: 'osdisk-${resourceToken}'
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
        timeZone: timeZoneId
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

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${virtualMachine.name}'
  location: location
  tags: tags
  properties: {
    status: autoShutdownEnabled ? 'Enabled' : 'Disabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: '0000'
    }
    timeZoneId: timeZoneId
    targetResourceId: virtualMachine.id
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
  }
}

output vmName string = virtualMachine.name
output vmId string = virtualMachine.id
output bastionName string = bastion.name
