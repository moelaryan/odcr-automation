// Deploys the ODCR automation Function App on a governed (no-shared-key) tenant.
// Uses identity-based storage (no listKeys) on a Basic dedicated plan (no content share).
param location string = resourceGroup().location
param storageAccountName string
param appName string
param planName string = 'odcr-demo-plan'
param workspaceName string = 'odcr-demo-logs'
param appInsightsName string = 'odcr-demo-ai'

// Built-in role definition IDs
var roleBlobOwner   = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
var roleQueueContrib= '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
var roleTableContrib= '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
var roleContributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor (for ODCR ops in this RG)

resource stg 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: { name: 'B1', tier: 'Basic' }
  properties: { reserved: false } // Windows
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      powerShellVersion: '7.4'
      netFrameworkVersion: 'v6.0'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        // identity-based host storage (no keys)
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccountName}.blob.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccountName}.queue.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccountName}.table.${environment().suffixes.storage}' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // ODCR settings consumed by the module
        { name: 'ODCR_RG', value: resourceGroup().name }
        { name: 'ODCR_GROUP', value: 'demoCRG' }
        { name: 'ODCR_NAME', value: 'demoRes' }
        { name: 'ODCR_LOCATION', value: location }
        { name: 'ODCR_SKU', value: 'Standard_D2s_v3' }
        { name: 'PROVISION_SCHEDULE', value: '0 45 7 * * 1-5' }
        { name: 'TEARDOWN_SCHEDULE', value: '0 15 19 * * 1-5' }
        // timers disabled until we finish HTTP testing
        { name: 'AzureWebJobs.ProvisionTimer.Disabled', value: 'true' }
        { name: 'AzureWebJobs.TeardownTimer.Disabled', value: 'true' }
      ]
    }
    httpsOnly: true
  }
}

// Function identity -> storage data-plane (host uses blob/queue/table)
resource raBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, func.id, roleBlobOwner)
  scope: stg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobOwner)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource raQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, func.id, roleQueueContrib)
  scope: stg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleQueueContrib)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource raTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, func.id, roleTableContrib)
  scope: stg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleTableContrib)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
// Function identity -> Contributor on this RG (create/delete capacity reservations)
resource raOdcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, func.id, roleContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContributor)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output appName string = func.name
output principalId string = func.identity.principalId
output appHost string = func.properties.defaultHostName
