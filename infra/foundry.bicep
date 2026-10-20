targetScope = 'resourceGroup'

param name string
param location string
param tags object

type modelDeployment = {
  name: string
  model: {
    format: 'OpenAI' | 'Anthropic'
    name: string
    version: string
  }
  @minValue(1)
  capacity: int
  modelProviderData: {
    organizationName: string
    countryCode: string
    industry: string
  }?
}

@minLength(1)
@maxLength(3)
param deployments modelDeployment[]

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: '${name}-project'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: '${name}-project'
    description: 'Agent Box models in ${location}'
  }
}

// Foundry serializes deployment writes within an account.
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = [for deployment in deployments: {
  parent: account
  name: deployment.name
  sku: {
    name: 'GlobalStandard'
    capacity: deployment.capacity
  }
  properties: union({
    model: deployment.model
    versionUpgradeOption: 'NoAutoUpgrade'
  }, deployment.?modelProviderData == null ? {} : {
    modelProviderData: deployment.?modelProviderData
  })
  dependsOn: [project]
}]

output accountName string = account.name
output accountId string = account.id
output projectName string = project.name
output projectId string = project.id
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output openAiBaseUrl string = 'https://${account.name}.openai.azure.com/openai/v1/'
output anthropicBaseUrl string = 'https://${account.name}.services.ai.azure.com/anthropic'
