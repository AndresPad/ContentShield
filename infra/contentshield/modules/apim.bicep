// API Management v2 with external VNet integration + full ContentShield wiring:
//   - 3 named values (aad-tenant-id, aad-api-audience, aad-api-client-id)
//   - 1 backend (be-contentshield → ca-ratio-contentshield FQDN)
//   - 1 API (ratio-contentshield-api at /contentshield) with 2 operations and the AAD-validating policy
//   - 1 Application Insights logger
//   - API-level diagnostic settings using that logger
//
// NOTE: Provisioning takes 30-45 minutes for the APIM service itself. Skip via
// deployApim=false in main.bicep during fast iteration.
// Andres

param location string
param tags object
param name string
param sku string = 'StandardV2'
param capacity int = 1
param publisherEmail string
param publisherName string
param subnetId string

@description('CAE default domain (e.g. blacksea-a90e1d7c.westus3.azurecontainerapps.io) — used to compute the backend FQDN.')
param caeDefaultDomain string

@description('Container app name that serves the API (used to construct the backend URL https://<appName>.<caeDefaultDomain>).')
param backendAppName string = 'ca-ratio-contentshield'

@description('AAD tenant id used by the validate-azure-ad-token policy.')
param aadTenantId string

@description('AAD audience claim that the API validates incoming bearer tokens against. Usually the API app registration client id.')
param aadApiAudience string

@description('AAD client (application) id of the API. Stored as a named value for reference in policies.')
param aadApiClientId string

@description('Application Insights resource id to wire as an APIM logger. Empty string skips logger + diagnostics.')
param appInsightsId string = ''

@description('Application Insights instrumentation key (used as the logger credential).')
@secure()
param appInsightsInstrumentationKey string = ''

@description('Path the API is exposed under (gateway URL becomes https://<apim>.azure-api.net/<apiPath>).')
param apiPath string = 'contentshield'

@description('API id (unique within APIM).')
param apiId string = 'ratio-contentshield-api'

@description('API display name shown in the developer portal.')
param apiDisplayName string = 'RATIO ContentShield API'

@description('Backend id (unique within APIM).')
param backendId string = 'be-contentshield'

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: subnetId
    }
    publicNetworkAccess: 'Enabled'
    natGatewayState: 'Enabled'
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'False'
    }
  }
}

// ── Named values ────────────────────────────────────────────────────────────

resource nvAadTenantId 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = {
  parent: apim
  name: 'aad-tenant-id'
  properties: {
    displayName: 'aad-tenant-id'
    value: aadTenantId
    secret: false
  }
}

resource nvAadApiAudience 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = {
  parent: apim
  name: 'aad-api-audience'
  properties: {
    displayName: 'aad-api-audience'
    value: aadApiAudience
    secret: false
  }
}

resource nvAadApiClientId 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = {
  parent: apim
  name: 'aad-api-client-id'
  properties: {
    displayName: 'aad-api-client-id'
    value: aadApiClientId
    secret: false
  }
}

// ── Backend → ca-ratio-contentshield ────────────────────────────────────────

var backendUrl = 'https://${backendAppName}.${caeDefaultDomain}'

resource backend 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: backendId
  properties: {
    description: 'Backend for ${backendAppName} Container App'
    url: backendUrl
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ── App Insights logger (optional) ──────────────────────────────────────────
// Wiring an AI logger auto-creates a secret named value with the instrumentation key,
// which is what shows up as 'Logger-Credentials-<guid>' in your live APIM.

resource aiLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for ${name}'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

// ── API ─────────────────────────────────────────────────────────────────────

resource api 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: apiId
  properties: {
    displayName: apiDisplayName
    path: apiPath
    protocols: [
      'https'
    ]
    serviceUrl: backendUrl
    subscriptionRequired: true
  }
}

// ── API operations ──────────────────────────────────────────────────────────

resource opHealth 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: api
  name: 'health'
  properties: {
    displayName: 'Health'
    method: 'GET'
    urlTemplate: '/health'
    templateParameters: []
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 200
        description: 'OK'
      }
    ]
  }
}

resource opDetect 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: api
  name: 'detect'
  properties: {
    displayName: 'Detect'
    method: 'POST'
    urlTemplate: '/v1/detect'
    templateParameters: []
    request: {
      queryParameters: []
      headers: []
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'OK'
      }
    ]
  }
}

// ── API-level policy (AAD validation + rate limit + correlation id + backend route) ──
// Note: triple-quoted strings in Bicep are NON-interpolating, so we use a placeholder
// and replace() to inject the backend id at compile time.
var apiPolicyXml = replace('''<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="{{aad-tenant-id}}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized">
      <audiences>
        <audience>{{aad-api-audience}}</audience>
      </audiences>
    </validate-azure-ad-token>
    <rate-limit calls="1000" renewal-period="60" remaining-calls-header-name="X-RateLimit-Remaining" total-calls-header-name="X-RateLimit-Limit" />
    <choose>
      <when condition="@(context.Request.Headers.ContainsKey(&quot;x-correlation-id&quot;))">
        <set-header name="x-correlation-id" exists-action="override">
          <value>@(context.Request.Headers.GetValueOrDefault("x-correlation-id",""))</value>
        </set-header>
      </when>
      <otherwise>
        <set-header name="x-correlation-id" exists-action="override">
          <value>@(context.RequestId.ToString())</value>
        </set-header>
      </otherwise>
    </choose>
    <set-backend-service backend-id="__BACKEND_ID__" />
    <set-header name="Authorization" exists-action="delete" />
  </inbound>
  <backend>
    <forward-request timeout="30" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>''', '__BACKEND_ID__', backendId)

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: apiPolicyXml
  }
  dependsOn: [
    nvAadTenantId
    nvAadApiAudience
    nvAadApiClientId
    backend
  ]
}

// ── API-level diagnostics tied to the App Insights logger ──────────────────

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2023-09-01-preview' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  parent: api
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
    backend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
  }
}

output id string = apim.id
output name string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
output backendId string = backend.name
output apiPath string = api.properties.path
