targetScope = 'resourceGroup'

param location string
param tags object
param resourceToken string
param adminUsername string

@secure()
param adminPassword string

@allowed([
  true
])
param confirmWindowsClientLicense bool
param vmSize string
@minValue(256)
@maxValue(1024)
param osDiskSizeGB int
param autoShutdownEnabled bool
param autoShutdownTime string

var vmName = 'vm-${resourceToken}'
var subnetName = 'snet-workstation'
var timeZoneId = 'Korea Standard Time'

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: 'nsg-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
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

resource nat 'Microsoft.Network/natGateways@2025-01-01' = {
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
        id: natIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
  name: 'vnet-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.40.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.40.0.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: nsg.id
          }
          natGateway: {
            id: nat.id
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
      id: vnet.id
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2025-01-01' = {
  name: 'nic-${resourceToken}'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetName)
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  tags: tags
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
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-26h2-ent'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: take('w11-${resourceToken}', 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        timeZone: timeZoneId
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
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
  name: 'shutdown-computevm-${vm.name}'
  location: location
  tags: tags
  properties: {
    status: autoShutdownEnabled ? 'Enabled' : 'Disabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: timeZoneId
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
  }
}

output vmName string = vm.name
output vmId string = vm.id
output bastionName string = bastion.name
