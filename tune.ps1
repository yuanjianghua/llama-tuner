# llama-tuner: auto-tune llama.cpp launch config for THIS machine.
# Entry point / orchestration ONLY. Logic lives in lib/*.ps1, offline tests in tests/smoke.ps1.
# ASCII-only source (safe on PS 5.1 with any codepage). Chinese labels use \u escapes.
#
# Usage:  tune.cmd                                  detect -> validate by real launches -> launchers + shortcuts + report
#         tune.ps1 -SkipValidate                    plan only, no test launches
#         tune.ps1 -ModelPath D:\x\model.gguf       explicit model
#         tune.ps1 -Force                           revalidate even if cached config matches hardware+model
param(
  [string]$ModelPath = '',
  [string]$LlamaDir  = '',
  [int]$Port = 8080,
  [switch]$SkipValidate,
  [switch]$NoShortcut,
  [switch]$NoDownload,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
foreach ($m in @('common', 'sysinfo', 'gguf', 'discover', 'plan', 'validate', 'launcher')) {
  . (Join-Path $root ("lib\" + $m + ".ps1"))
}
$cfgPath    = Join-Path $root 'config.json'
$reportPath = Join-Path $root 'tuning_report.txt'
$startCmd   = Join-Path $root 'start_llm.cmd'
$stopCmd    = Join-Path $root 'stop_llm.cmd'
$runtimeDir = Join-Path $root 'runtime'

try {
  Write-TuneLog "=== llama-tuner $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

  # 1. machine (a running server would poison VRAM/RAM readings and validation runs)
  if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-TuneLog 'Stopping running llama-server for clean measurement...'
    Stop-TuneServer
  }
  $ramMB = Get-TuneRamMB
  Write-TuneLog ("RAM total: {0} GB" -f [Math]::Round($ramMB / 1024, 1))
  $gpu = Get-TuneGpuSummary
  if ($gpu) {
    Write-TuneLog ("GPU x{0}: {1}" -f $gpu.Count, (($gpu.List | ForEach-Object { "$($_.Name) $($_.TotalMB)MB (used $($_.UsedMB)MB)" }) -join '; '))
    if ($gpu.Count -gt 1) { Write-TuneLog 'Multi-GPU: VRAM budgets aggregated; per-GPU overhead reserved; tensor-split proportional to card size. Cross-card sync runs over PCIe, gains are sub-linear.' }
  } else {
    Write-TuneLog 'GPU: no NVIDIA GPU detected -> CPU-only plan (AMD/Vulkan users: tune manually)'
  }

  # 2. model structure
  $model = Find-TuneModel $ModelPath $cfgPath
  $modelBytes = (Get-Item $model).Length
  $modelMB = [Math]::Round($modelBytes / 1MB)
  Write-TuneLog "Model: $model  ($([Math]::Round($modelMB/1024,2)) GiB)"
  $hdr = Parse-GgufHeader $model
  $layout = Get-GgufLayout $hdr $modelBytes

  # 3. plan (pure math in lib/plan.ps1)
  $p = New-TunePlan $model $modelMB $ramMB $layout $gpu $Port
  $plan = $p.Plan
  Write-TuneLog ("Plan ctx={0}  KV={1} MB ({2})  gpu reserve={3} MB" -f $plan.NCtx, $p.KVMB, $(if ($plan.KvQ8) { 'q8_0' } else { 'f16' }), $p.ReserveMB)
  if ($p.Kmax -ge $layout.NLayers) { Write-TuneLog 'Model fits fully in VRAM -> full offload (no expert split needed).' }
  elseif ($gpu -and $plan.Kind -eq 'moe') { Write-TuneLog ("Max experts resident layers (estimate): K={0} (each layer keeps its experts on GPU)" -f $p.Kmax) }
  elseif ($gpu) { Write-TuneLog ("Dense model partial offload (estimate): ngl={0}" -f $p.Kmax) }
  else { Write-TuneLog 'CPU-only mode.' }
  if ($modelMB -gt $ramMB) { Write-TuneLog 'NOTE: model larger than RAM -> NVMe page cache tiering; close big apps while running for best speed.' }

  # 4. llama.cpp location (+ optional auto-install)
  $llamaDir = Find-TuneLlama $LlamaDir $cfgPath $root
  if (-not $llamaDir) {
    if ($NoDownload) { throw 'llama-server.exe not found and -NoDownload set.' }
    $llamaDir = Install-TuneLlama $(if ($gpu) { $gpu.TotalMB } else { 0 }) $root
  }
  $llamaExe = Join-Path $llamaDir 'llama-server.exe'
  Write-TuneLog "llama.cpp: $llamaDir"

  # 5. validated K (cached unless hardware/model changed or -Force)
  $Kbest = $p.Kmax
  $cfgData = $null
  if (Test-Path $cfgPath) { try { $cfgData = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch {} }
  $gpuSig = $(if ($gpu) { $gpu.Sig } else { 'cpu' })
  if (-not $SkipValidate -and $p.Kmax -gt 0 -and $gpu) {
    if ($cfgData -and (-not $Force) -and $null -ne $cfgData.K -and $cfgData.GpuSig -eq $gpuSig -and $cfgData.ModelPath -eq $model) {
      $Kbest = [Math]::Min([int]$cfgData.K, $p.Kmax)
      Write-TuneLog ("Reusing validated K=$Kbest (hardware and model unchanged; use -Force to revalidate)")
    } else {
      $Kbest = (Find-BestTuneK $plan $p.Kmax $llamaExe $runtimeDir).K
    }
  }

  # 6. artifacts
  $bodies = New-TuneLauncherBodies $plan (Build-TuneArgs $plan $Kbest) $llamaExe
  Write-TuneLaunchers $startCmd $stopCmd $bodies $plan ([bool]$NoShortcut) $root
  $cfg = @{ ModelPath = $model; LlamaDir = $llamaDir; Port = $Port; K = $Kbest;
            Kind = $plan.Kind; NCtx = $plan.NCtx; KvQ8 = $plan.KvQ8; GpuSig = $gpuSig; TunedAt = (Get-Date).ToString('o') }
  Set-Content -Path $cfgPath -Value ($cfg | ConvertTo-Json) -Encoding ASCII
  Write-TuneLog "Saved $cfgPath"
  Write-TuneLog '=== DONE. Use the desktop shortcuts (or start_llm.cmd). First requests are slower until page cache warms up. ==='
  Save-TuneLog $reportPath
} catch {
  Write-TuneLog ("ERROR: " + $_.Exception.Message)
  Write-TuneLog 'Fix the issue and re-run tune.cmd'
  Save-TuneLog $reportPath
  exit 1
}
