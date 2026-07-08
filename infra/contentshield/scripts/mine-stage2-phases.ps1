<#
.SYNOPSIS
  Mine ACA system + console logs for cold-start phase timestamps.

.DESCRIPTION
  Reads the last N system + console log lines for a Stage-2 variant and emits a
  timeline of K8s-level + vLLM-level events:
    PullingImage / SuccessfulPulled
    Started / Created
    "Loading model weights"
    "Model loaded"
    "Started server process" / "Application startup complete"
  Used as a post-mortem complement to test-stage2-variants.ps1 (which captures
  scale->replica and scale->health from the outside).

.EXAMPLE
  ./mine-stage2-phases.ps1 -ResourceGroup rg-contentshield -Variant ca-cs-stage2-baked-local
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$Variant,
  [int]$Tail = 300,
  [DateTime]$T0
)

function Mine([string]$type, [string]$pattern, [string]$container) {
  $args = @('containerapp','logs','show','-g',$ResourceGroup,'-n',$Variant,'--type',$type,'--tail',$Tail.ToString())
  if ($container) { $args += @('--container',$container) }
  $lines = & az @args 2>$null
  $matches = @()
  foreach ($line in $lines) {
    if ($line -match [regex]::Escape($pattern)) {
      $tsMatch = [regex]::Match($line, '"TimeStamp"\s*:\s*"([^"]+)"')
      if (-not $tsMatch.Success) { $tsMatch = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"') }
      if ($tsMatch.Success) {
        try { $matches += [DateTime]::Parse($tsMatch.Groups[1].Value).ToUniversalTime() } catch {}
      }
    }
  }
  if ($matches.Count -gt 0) { return ($matches | Sort-Object)[0] }
  return $null
}

Write-Host "=== Mining phase timestamps for $Variant ===" -ForegroundColor Green
Write-Host "tail=$Tail"

$events = [ordered]@{
  'PullingImage'           = Mine 'system'  'Pulling image'                  $Variant
  'SuccessfulPulled'       = Mine 'system'  'Successfully pulled image'      $Variant
  'StartedContainer'       = Mine 'system'  'Started container'              $Variant
  'CreatedContainer'       = Mine 'system'  'Created container'              $Variant
  'VllmLoadingWeights'     = Mine 'console' 'Loading model'                  $Variant
  'VllmModelLoaded'        = Mine 'console' 'model loaded'                   $Variant
  'VllmEngineStarted'      = Mine 'console' 'Started server process'         $Variant
  'FastApiStartupComplete' = Mine 'console' 'Application startup complete'   $Variant
  'GpuMemReady'            = Mine 'console' 'GPU memory'                     $Variant
  'EngineCoreReady'        = Mine 'console' 'EngineCore'                     $Variant
}

Write-Host "`nDiscovered events (UTC):"
$baseline = if ($T0) { $T0.ToUniversalTime() } else {
  # First event we can find
  $first = $events.Values | Where-Object { $_ } | Sort-Object | Select-Object -First 1
  $first
}
Write-Host "  baseline (t0): $baseline" -ForegroundColor Cyan
foreach ($k in $events.Keys) {
  $t = $events[$k]
  if ($t) {
    $delta = if ($baseline) { [Math]::Round(($t - $baseline).TotalSeconds, 1) } else { '?' }
    Write-Host ("  {0,-25} {1} (+{2}s)" -f $k, $t.ToString('HH:mm:ss.fff'), $delta)
  } else {
    Write-Host ("  {0,-25} (not found in last $Tail lines)" -f $k) -ForegroundColor DarkGray
  }
}

Write-Host "`nDerived phases:"
function Span($from, $to) {
  if (-not $events[$from] -or -not $events[$to]) { return '(missing)' }
  return "$([Math]::Round(($events[$to] - $events[$from]).TotalSeconds, 1)) s"
}
Write-Host "  imagePull          : $(Span 'PullingImage' 'SuccessfulPulled')"
Write-Host "  containerToVllm    : $(Span 'StartedContainer' 'VllmLoadingWeights')"
Write-Host "  vllmModelLoad      : $(Span 'VllmLoadingWeights' 'VllmModelLoaded')"
Write-Host "  vllmToFastapiReady : $(Span 'VllmModelLoaded' 'FastApiStartupComplete')"
Write-Host "  totalPullToReady   : $(Span 'PullingImage' 'FastApiStartupComplete')"
