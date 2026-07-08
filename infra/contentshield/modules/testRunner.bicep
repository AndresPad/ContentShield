// In-VNet test runner container app: tiny image with curl baked in.
// Used by scripts/test-stage2-variants.ps1 via `az containerapp exec` to
// probe internal Stage-2 endpoints (health + classify).
//
// Image: curlimages/curl on Docker Hub (~10 MB). Pulled directly; no ACR
// import required. We mirror it through the customer ACR only if Docker Hub
// rate limiting becomes an issue.

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Container Apps Environment name (must exist).')
param caeName string

@description('Container app name.')
param name string = 'ca-test-runner'

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: caeName
}

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: null
    }
    template: {
      containers: [
        {
          name: 'runner'
          image: 'mcr.microsoft.com/cbl-mariner/base/core:2.0'
          command: [
            '/bin/bash'
            '-c'
            'tdnf install -y curl ca-certificates >/dev/null 2>&1 || true; echo IyEvYmluL3NoClVSTD0kMQpNRVRIT0Q9JHsyOi1HRVR9CkI2ND0kMwpGTVQ9J0hUVFA9JXtodHRwX2NvZGV9X1RJTUU9JXt0aW1lX3RvdGFsfScKaWYgWyAiJE1FVEhPRCIgPSAiR0VUIiBdOyB0aGVuCiAgZXhlYyBjdXJsIC1zUyAtayAtbyAvZGV2L251bGwgLXcgIiRGTVQiIC0tbWF4LXRpbWUgMzAgIiRVUkwiCmZpCkJPRFk9JChlY2hvICIkQjY0IiB8IGJhc2U2NCAtZCkKZXhlYyBjdXJsIC1zUyAtayAtbyAvZGV2L251bGwgLXcgIiRGTVQiIC0tbWF4LXRpbWUgNjAgLVggIiRNRVRIT0QiIC1IICdDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24nIC1kICIkQk9EWSIgIiRVUkwi | base64 -d > /usr/local/bin/probe && chmod +x /usr/local/bin/probe && echo IyEvYmluL3NoCiMgVXNhZ2U6IGJlbmNoIFVSTCBNRVRIT0QgQkFTRTY0X0JPRFkgW049MTBdIFtDPTFdCiMgRW1pdHMgTiBsaW5lcyBvZiBjdXJsIHRpbWVfdG90YWwgKHNlY29uZHMpIHRvIHN0ZG91dCwgb25lIHBlciByZXF1ZXN0LgpVUkw9JDEKTUVUSE9EPSR7MjotR0VUfQpCNjQ9JDMKTj0kezQ6LTEwfQpDPSR7NTotMX0KRk1UPScle3RpbWVfdG90YWx9XG4nCmlmIFsgIiRNRVRIT0QiID0gIkdFVCIgXTsgdGhlbgogIHNlcSAkTiB8IHhhcmdzIC1uMSAtUCAkQyAtSSBYWCBjdXJsIC1zUyAtayAtbyAvZGV2L251bGwgLXcgIiRGTVQiIC0tbWF4LXRpbWUgNjAgIiRVUkwiCmVsc2UKICBlY2hvICIkQjY0IiB8IGJhc2U2NCAtZCA+IC90bXAvYmVuY2gtYm9keS5qc29uCiAgc2VxICROIHwgeGFyZ3MgLW4xIC1QICRDIC1JIFhYIGN1cmwgLXNTIC1rIC1vIC9kZXYvbnVsbCAtdyAiJEZNVCIgLS1tYXgtdGltZSA2MCAtWCAiJE1FVEhPRCIgLUggJ0NvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbicgLS1kYXRhLWJpbmFyeSBAL3RtcC9iZW5jaC1ib2R5Lmpzb24gIiRVUkwiCmZp | base64 -d > /usr/local/bin/bench && chmod +x /usr/local/bin/bench && while true; do sleep 3600; done'
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output name string = app.name
output principalId string = app.identity.principalId
