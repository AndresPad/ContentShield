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
//
// Two source modes (selected via modelSource):
//   * 'hf-hub'   (default, back-compat): `huggingface-cli download <model>`
//                from huggingface.co. Requires public-internet egress.
//   * 'acr-oras' (preferred for prod):   `oras pull` the weights OCI
//                artifact from the customer ACR (populated by
//                sync-weights-from-vendor.ps1), then untar into $HF_HOME.
//                Uses the job's system-assigned MI + IMDS for ACR auth
//                — no `az` CLI inside the container.
//
// Trigger:
//   deploy.ps1 fires `az containerapp job start` after a successful deploy.
//   Both modes are idempotent — HF and tar skip already-present files.

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

@description('Source of the model weights. "hf-hub" downloads from huggingface.co (back-compat default); "acr-oras" pulls the OCI weights artifact from a customer ACR via the job\'s managed identity.')
@allowed([
  'hf-hub'
  'acr-oras'
])
param modelSource string = 'hf-hub'

@description('ACR resource name holding the weights OCI artifact (required when modelSource = "acr-oras"). Typically the customer ACR.')
param weightsAcrName string = ''

@description('Login server FQDN of the weights ACR, e.g. contentshieldacrXXX.azurecr.io (required when modelSource = "acr-oras").')
param weightsAcrLoginServer string = ''

@description('Repository name of the weights artifact in the customer ACR.')
param weightsRepository string = 'contentshield-stage2-weights'

@description('Tag of the weights artifact to pull (required when modelSource = "acr-oras"). Convention: same semver as the stage-2 image tag.')
param weightsTag string = ''

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

var isAcrOras = modelSource == 'acr-oras'

var jobSecrets = empty(hfToken) ? [] : [
  {
    name: 'hf-token'
    value: hfToken
  }
]

var jobEnvBase = [
  {
    name: 'MODEL_SOURCE'
    value: modelSource
  }
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
    name: 'WEIGHTS_ACR_FQDN'
    value: weightsAcrLoginServer
  }
  {
    name: 'WEIGHTS_REPOSITORY'
    value: weightsRepository
  }
  {
    name: 'WEIGHTS_TAG'
    value: weightsTag
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

// Branching script:
//   * MODEL_SOURCE=hf-hub   — huggingface-cli download (back-compat)
//   * MODEL_SOURCE=acr-oras — oras pull from customer ACR via job MI + IMDS
var downloadScript = '''
set -euo pipefail
echo "[prewarm] source=$MODEL_SOURCE  model=$MODEL_NAME  cache=$HF_HOME"
mkdir -p "$HF_HOME"
df -h "$HF_HOME" || true

case "$MODEL_SOURCE" in
  hf-hub)
    echo "[prewarm] installing huggingface_hub + hf_transfer..."
    python -m pip install --quiet --no-cache-dir --disable-pip-version-check \
        'huggingface_hub[cli]>=0.24' 'hf_transfer>=0.1.6'
    echo "[prewarm] downloading from HF Hub..."
    time huggingface-cli download "$MODEL_NAME" --cache-dir "$HF_HOME" --quiet
    ;;
  acr-oras)
    : "${WEIGHTS_ACR_FQDN:?WEIGHTS_ACR_FQDN must be set for acr-oras mode}"
    : "${WEIGHTS_REPOSITORY:?WEIGHTS_REPOSITORY must be set for acr-oras mode}"
    : "${WEIGHTS_TAG:?WEIGHTS_TAG must be set for acr-oras mode}"
    echo "[prewarm] target artifact: $WEIGHTS_ACR_FQDN/$WEIGHTS_REPOSITORY:$WEIGHTS_TAG"

    # 1) Install oras (pinned, single binary).
    ORAS_VERSION=1.2.3
    echo "[prewarm] installing oras $ORAS_VERSION..."
    tdnf install -y -q tar gzip curl ca-certificates >/dev/null 2>&1 || \
      (apt-get update -qq && apt-get install -y -qq tar gzip curl ca-certificates >/dev/null) || true
    curl -fsSL -o /tmp/oras.tgz \
      "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    tar -xzf /tmp/oras.tgz -C /usr/local/bin oras
    chmod +x /usr/local/bin/oras
    oras version

    # 2) Exchange the job\'s managed identity (via IMDS) for an ACR access token.
    echo "[prewarm] authenticating to $WEIGHTS_ACR_FQDN via managed identity..."
    AAD_TOKEN=$(curl -fsSL -H "Metadata:true" \
      "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://${WEIGHTS_ACR_FQDN}/" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    REFRESH=$(curl -fsSL -X POST "https://$WEIGHTS_ACR_FQDN/oauth2/exchange" \
      -d "grant_type=access_token&service=$WEIGHTS_ACR_FQDN&access_token=$AAD_TOKEN" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['refresh_token'])")
    ACCESS=$(curl -fsSL -X POST "https://$WEIGHTS_ACR_FQDN/oauth2/token" \
      -d "grant_type=refresh_token&service=$WEIGHTS_ACR_FQDN&scope=repository:${WEIGHTS_REPOSITORY}:pull&refresh_token=${REFRESH}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    printf '%s' "$ACCESS" | oras login "$WEIGHTS_ACR_FQDN" \
      -u '00000000-0000-0000-0000-000000000000' --password-stdin

    # 3) Pull the artifact (one or more tarball layers) into a staging dir.
    STAGE=/tmp/weights
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    echo "[prewarm] pulling artifact..."
    time oras pull "$WEIGHTS_ACR_FQDN/${WEIGHTS_REPOSITORY}:${WEIGHTS_TAG}" -o "$STAGE"

    # 4) Untar each layer into HF_HOME. Supports .tar.gz, .tar.zst, .tar.
    echo "[prewarm] extracting to $HF_HOME ..."
    shopt -s nullglob
    for f in "$STAGE"/*.tar.gz "$STAGE"/*.tgz; do
      echo "  + $f"
      tar -xzf "$f" -C "$HF_HOME"
    done
    for f in "$STAGE"/*.tar.zst; do
      echo "  + $f (zstd)"
      # Mariner has zstd in tdnf; install on demand.
      command -v zstd >/dev/null 2>&1 || tdnf install -y -q zstd >/dev/null 2>&1 || \
        apt-get install -y -qq zstd >/dev/null 2>&1 || true
      tar --use-compress-program=unzstd -xf "$f" -C "$HF_HOME"
    done
    for f in "$STAGE"/*.tar; do
      echo "  + $f"
      tar -xf "$f" -C "$HF_HOME"
    done
    rm -rf "$STAGE"
    ;;
  *)
    echo "[prewarm] ERROR: unknown MODEL_SOURCE=$MODEL_SOURCE" >&2
    exit 2
    ;;
esac

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
            '/bin/bash'
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
output modelSource string = modelSource

// ---------------------------------------------------------------------------
// Optional role assignment: job MI → AcrPull on the weights ACR.
// Only when modelSource = 'acr-oras' (otherwise the job never touches ACR).
// ---------------------------------------------------------------------------
resource weightsAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (isAcrOras && !empty(weightsAcrName)) {
  name: weightsAcrName
}

resource acrPullForJob 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (isAcrOras && !empty(weightsAcrName)) {
  scope: weightsAcr
  // Deterministic GUID so reruns are idempotent.
  name: guid(weightsAcr.id, job.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  properties: {
    // AcrPull built-in role.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
