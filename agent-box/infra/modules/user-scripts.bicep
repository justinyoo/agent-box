targetScope = 'resourceGroup'

param location string
param vmName string
param adminUsername string
param tags object
@minLength(1)
@maxLength(90000)
param scriptPayload string

var stagingScript = replace(
  replace(
    loadTextContent('../scripts/stage-user-scripts.ps1'),
    '__PAYLOAD_BASE64__',
    scriptPayload
  ),
  '__ADMIN_USERNAME_BASE64__',
  base64(adminUsername)
)

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

resource delivery 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = {
  parent: vm
  name: 'stage-agent-box-user-scripts'
  location: location
  tags: tags
  properties: {
    source: {
      script: stagingScript
    }
    asyncExecution: false
    timeoutInSeconds: 300
    treatFailureAsDeploymentFailure: true
  }
}

output runCommandName string = delivery.name
