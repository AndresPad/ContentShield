// HuggingFace cache pre-warm job (Microsoft.App/jobs).
//
// Purpose:
//   Stage-2 mounts an NFS share at $HF_HOME. On first cold start, vLLM
//   downloads the SLM weights (~6-15 GB) from huggingface.co — that adds
//   5-10 minutes to the first replica start after a fresh storage account
//   or a model bump. This job populates the share BEFORE traffic arrives.
//
// Shape:
//   - Manual-trigger Container Apps Job (not a regular app).
//   - Consumption profile (no GPU needed — just network + disk).
//   - Same NFS volume + mount path as ca-contentshield-stage2 so the cache
//     it writes is exactly what the GPU app will read on next cold start.
//   - Uses a small MS-hosted Python base image (no Docker Hub rate limit).
//   - Runs `huggingface-cli download <model>` with HF_HUB_ENABLE_HF_TRANSFER
//     for parallel chunked downloads.
//
// Trigger:
//   deploy.ps1 fires `az containerapp job start` after a successful deploy.
//   The job is idempotent — HF's local cache logic skips already-present
//   blobs, so re-running is cheap.

param location string
param tags object
param caeName string
param jobName string = 'job-hf-prewarm'

@description('Model id to pre-download into the HF cache (e.g. google/gemma-4-31b-it).')
param model string

@description('Storage account name. Used to compute the mount path /mount/<accountName>/<share> — must match what stage-2 uses.')
param storageAccountName string

@description('NFS share name registered on the CAE as a storage definition (must already exist as a managedEnvironments/storages child).')
param hfCacheShareName string = 'hfcache'

@description('CAE storage definition name to bind. Defaults to "hfcache" (the one defined in containerAppsEnv.bicep).')
param caeStorageName string = 'hfcache'

@description('Optional HF token for gated/private models.')
@secure()
param hfToken string = ''

@description('App Insights connection string — surfaced to the job for traceability.')
param appInsightsConnectionString string = ''

@description('Image used to run the download. MS-hosted to avoid Docker Hub rate limits.')
param prewarmImage string = 'mcr.microsoft.com/azurelinux/base/python:3.12'

@description('Job replica timeout in seconds. Default 3600 (1h) — generous for cold cache + large models.')
@minValue(300)
@maxValue(86400)
param replicaTimeoutSeconds int = 3600

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: caeName
}

var hfCacheMountPath = '/mount/${storageAccountName}/${hfCacheShareName}'

var jobSecrets = empty(hfToken) ? [] : [
  {
    name: 'hf-token'
    value: hfToken
  }
]

var jobEnvBase = [
  {
    name: 'MODEL_NAME'
    value: model
  }
  {
    name: 'HF_HOME'
    value: hfCacheMountPath
  }
  {
    name: 'HF_HUB_ENABLE_HF_TRANSFER'
    value: '1'
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
]

var jobEnv = empty(hfToken) ? jobEnvBase : concat([
  {
    name: 'HF_TOKEN'
    secretRef: 'hf-token'
  }
], jobEnvBase)

// The command:
//   1. pip-install huggingface_hub[cli] + hf_transfer (small, ~30 s)
//   2. huggingface-cli download "$MODEL_NAME" --cache-dir "$HF_HOME"
//      (HF skips files that already exist; safe to re-run.)
//   3. ls / du for a visible footprint in the job logs.
var downloadScript = '''
set -eu
echo "[prewarm] model=$MODEL_NAME"
echo "[prewarm] cache=$HF_HOME"
mkdir -p "$HF_HOME"
df -h "$HF_HOME" || true
echo "[prewarm] installing huggingface_hub + hf_transfer..."
python -m pip install --quiet --no-cache-dir --disable-pip-version-check 'huggingface_hub[cli]>=0.24' 'hf_transfer>=0.1.6'
echo "[prewarm] downloading..."
time huggingface-cli download "$MODEL_NAME" --cache-dir "$HF_HOME" --quiet
echo "[prewarm] done. footprint:"
du -sh "$HF_HOME" || true
'''

resource job 'Microsoft.App/jobs@2024-10-02-preview' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: replicaTimeoutSeconds
      replicaRetryLimit: 1
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      secrets: jobSecrets
    }
    template: {
      containers: [
        {
          name: 'prewarm'
          image: prewarmImage
          command: [
            '/bin/sh'
            '-c'
            downloadScript
          ]
          env: jobEnv
          resources: {
            cpu: json('2.0')
            memory: '4Gi'
          }
          volumeMounts: [
            {
              mountPath: hfCacheMountPath
              volumeName: 'hfcache'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'hfcache'
          storageName: caeStorageName
          storageType: 'NfsAzureFile'
        }
      ]
    }
  }
}

output jobName string = job.name
output jobId string = job.id
output mountPath string = hfCacheMountPath
