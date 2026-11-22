# lib/state.ps1 - persisted tuning config (config.json). Data access only: no logging,
# no decisions beyond "does this cache still apply". ASCII-only.

function Read-TuneConfig([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}

# Cached validated K when the config was produced for this exact hardware + model + context, else -1.
# Context matters: K is validated by real launches, and ctx changes the KV footprint. Without this
# check a ctx-policy upgrade (e.g. KV-budget pick moving 16k -> 32k) would silently reuse a K that
# was only ever validated at the old context.
function Get-TuneCachedK($cfg, [string]$gpuSig, [string]$modelPath, [int]$ctx) {
  if (-not $cfg) { return -1 }
  if ($null -eq $cfg.K) { return -1 }
  if ([string]$cfg.GpuSig -ne $gpuSig) { return -1 }
  if ([string]$cfg.ModelPath -ne $modelPath) { return -1 }
  if ($ctx -gt 0 -and [int]$cfg.NCtx -ne $ctx) { return -1 }
  return [int]$cfg.K
}

function Write-TuneConfig([string]$path, $cfg) {
  Set-Content -Path $path -Value ($cfg | ConvertTo-Json) -Encoding ASCII
}
