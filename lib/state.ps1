# lib/state.ps1 - persisted tuning config (config.json). Data access only: no logging,
# no decisions beyond "does this cache still apply". ASCII-only.

function Read-TuneConfig([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}

# Cached validated K when the config was produced for this exact hardware + model, else -1.
function Get-TuneCachedK($cfg, [string]$gpuSig, [string]$modelPath) {
  if (-not $cfg) { return -1 }
  if ($null -eq $cfg.K) { return -1 }
  if ([string]$cfg.GpuSig -ne $gpuSig) { return -1 }
  if ([string]$cfg.ModelPath -ne $modelPath) { return -1 }
  return [int]$cfg.K
}

function Write-TuneConfig([string]$path, $cfg) {
  Set-Content -Path $path -Value ($cfg | ConvertTo-Json) -Encoding ASCII
}
