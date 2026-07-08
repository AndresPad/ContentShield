# Overnight orchestration: test all 3 Stage-2 variants and emit a summary.
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-contentshield',
  [string]$CaeName       = 'cae-contentshield-axa1',
  [string]$Location      = 'westus3',
  [string]$OutDir        = $env:TEMP
)

$ErrorActionPreference = 'Continue'
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "overnight-$ts.log"
$csv = Join-Path $OutDir "overnight-$ts.csv"
$sum = Join-Path $OutDir "overnight-$ts.summary.md"

function Log($m) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
  Add-Content -Path $log -Value $line
  Write-Host $line
}

Log "=== overnight-run START ==="
Log "RG=$ResourceGroup CAE=$CaeName"
Log "log=$log csv=$csv summary=$sum"

$variants = @(
  'ca-cs-stage2-baked-local',
  'ca-cs-stage2-baked',
  'ca-cs-stage2-cache-disabled'
)

# Scale all variants to 0 first
Log "Scaling all variants to 0 (clean cold-start state)..."
foreach ($v in $variants) {
  az containerapp update -g $ResourceGroup -n $v --min-replicas 0 --max-replicas 1 --output none 2>&1 | Out-Null
  Log "  scaled $v to 0/1"
}

# Wait 90s for prior replicas to drain
Log "Waiting 90s for replicas to drain..."
Start-Sleep -Seconds 90

# Run harness for each variant individually so a failure in one doesn't stop the rest
$scriptRoot = Split-Path -Parent $PSCommandPath
$harness    = Join-Path $scriptRoot 'test-stage2-variants.ps1'
$results = @()
foreach ($v in $variants) {
  Log "----- BEGIN smoke: $v -----"
  $variantCsv = Join-Path $OutDir "overnight-$ts-$v.csv"
  $out = & $harness `
    -ResourceGroup $ResourceGroup `
    -Variants $v `
    -CaeName $CaeName `
    -Location $Location `
    -WarmRequests 9 `
    -ColdStartTimeoutSec 2400 `
    -OutCsv $variantCsv 2>&1
  $out | ForEach-Object { Add-Content -Path $log -Value "    $_" }
  Log "----- END smoke: $v (exit=$LASTEXITCODE) -----"
  if (Test-Path $variantCsv) {
    Get-Content $variantCsv | ForEach-Object { Add-Content -Path $csv -Value $_ }
    $results += [pscustomobject]@{ Variant = $v; CsvPath = $variantCsv; Ok = $true }
  } else {
    $results += [pscustomobject]@{ Variant = $v; CsvPath = ''; Ok = $false }
  }

  # Scale variant back to 0 between tests to free the GPU node
  az containerapp update -g $ResourceGroup -n $v --min-replicas 0 --output none 2>&1 | Out-Null
  Log "Scaled $v back to 0; sleeping 60s before next variant..."
  Start-Sleep -Seconds 60
}

# Emit summary
Log "Writing summary $sum"
"# Overnight smoke summary $ts`n" | Out-File $sum
"## Variants tested`n" | Add-Content $sum
foreach ($r in $results) {
  "- $($r.Variant) -> ok=$($r.Ok) csv=$($r.CsvPath)" | Add-Content $sum
}
"`n## Aggregated results`n" | Add-Content $sum
if (Test-Path $csv) {
  '```' | Add-Content $sum
  Get-Content $csv | Add-Content $sum
  '```' | Add-Content $sum
}

Log "=== overnight-run END ==="
