// Emails the ODCR daily outcome (fulfilled / partial / failed) via one alert rule per status.
// Matches the 'ODCR_STATUS=...' signal emitted by the DeadlineCheck function.
param location string = resourceGroup().location
param appInsightsName string
param alertEmail string = ''
param teamsWebhookUrl string = ''
param smsCountryCode string = '1'
param smsPhoneNumber string = ''

resource ai 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'odcr-alerts-ag'
  location: 'global'
  properties: {
    groupShortName: 'odcrAlert'
    enabled: true
    emailReceivers: empty(alertEmail) ? [] : [
      {
        name: 'ops'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: empty(teamsWebhookUrl) ? [] : [
      {
        name: 'teams'
        serviceUri: teamsWebhookUrl
        useCommonAlertSchema: true
      }
    ]
    smsReceivers: empty(smsPhoneNumber) ? [] : [
      {
        name: 'sms'
        countryCode: smsCountryCode
        phoneNumber: smsPhoneNumber
      }
    ]
  }
}

// One notification per daily outcome: fulfilled, partial, or failed.
var statuses = [
  { key: 'fulfilled', token: 'ODCR_STATUS=FULFILLED', severity: 3, title: 'ODCR capacity FULFILLED' }
  { key: 'partial',   token: 'ODCR_STATUS=PARTIAL',   severity: 2, title: 'ODCR capacity PARTIALLY fulfilled' }
  { key: 'failed',    token: 'ODCR_STATUS=FAILED',    severity: 1, title: 'ODCR capacity acquisition FAILED' }
]

resource statusAlerts 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for s in statuses: {
  name: 'odcr-status-${s.key}'
  location: location
  properties: {
    displayName: s.title
    description: 'Daily ODCR acquisition outcome notification.'
    severity: s.severity
    enabled: true
    scopes: [ ai.id ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'union traces, exceptions | where message has "${s.token}" or outerMessage has "${s.token}"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [ actionGroup.id ]
    }
    autoMitigate: true
  }
}]
