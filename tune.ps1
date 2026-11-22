# llama-tuner: auto-tune llama.cpp launch config for THIS machine.
# Entry point / orchestration ONLY (defines no logic functions; tests/arch.ps1 enforces this).
# Modules in lib/, load order + allowed dependencies declared in lib/modules.json.
# Offline tests: tests/arch.ps1 (coupling audit) + tests/smoke.ps1 (behavior regressions).
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
  [switch]$Force,
  [switch]$FixPagefile,
  [switch]$CpuOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
. (Join-Path $root 'lib\load.ps1')
foreach ($mp in Get-TuneModulePaths $root) { . $mp }
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
    if (-not $CpuOnly -and (Test-TuneNvidiaDevicePresent)) {
      Write-TuneLog 'ERROR: NVIDIA GPU detected at device level, but nvidia-smi does not work - the driver is missing or broken.'
      Write-TuneLog '       A CPU-only run would be ~10x slower than this machine can do. Install the driver first:'
      Write-TuneLog '       Windows Update > Advanced options > Optional updates, OR https://www.nvidia.com/en-us/drivers/'
      Write-TuneLog '       Then re-run tune.cmd.  (Want CPU-only on purpose? re-run with -CpuOnly.)'
      throw 'NVIDIA driver missing (GPU present, nvidia-smi unusable)'
    }
    Write-TuneLog 'GPU: no NVIDIA GPU detected -> CPU-only plan (AMD/Vulkan users: tune manually)'
  }

  # 2. model structure
  $model = Find-TuneModel $ModelPath $cfgPath
  $modelBytes = (Get-Item $model).Length
  $modelMB = [Math]::Round($modelBytes / 1MB)
  Write-TuneLog "Model: $model  ($([Math]::Round($modelMB/1024,2)) GiB)"
  $drvFree = (Get-PSDrive -Name $model.Substring(0, 1) -ErrorAction SilentlyContinue).Free
  if ($drvFree -and $drvFree -lt ($modelBytes + 4GB)) {
    Write-TuneLog ("WARNING: drive " + $model.Substring(0,1) + ": has only " + [Math]::Round($drvFree/1GB) + " GB free - expect model size + several GB headroom (pagefile/scratch); free up space for reliable runs.")
  }
  Write-TuneLog "Parsing GGUF header: $model"
  $hdr = Parse-GgufHeader $model
  $layout = Get-GgufLayout $hdr $modelBytes
  Write-TuneLog ("Arch: {0}  layers={1} (kv layers={2}, full_attn_interval={3})  kv_heads={4}  head_dim={5}  moe={6}" -f `
      $layout.Arch, $layout.NLayers, $layout.KvLayers, $layout.FaInt, $layout.KvHeads, $layout.HeadDim, $layout.IsMoE)
  Write-TuneLog ("MoE experts: {0} GB total, ~{1:N0} MB/layer; non-expert weights: {2} GB" -f `
      [Math]::Round($layout.ExpertBytes / 1GB, 2), $layout.PerLayerExpertMB, [Math]::Round($layout.NonExpertBytes / 1GB, 2))

  # 3. plan (pure math in lib/plan.ps1)
  $p = New-TunePlan $model $modelMB $ramMB $layout $gpu $Port
  $plan = $p.Plan
  Write-TuneLog ("Plan ctx={0}  KV={1} MB ({2})  gpu reserve={3} MB" -f $plan.NCtx, $p.KVMB, $(if ($plan.KvQ8) { 'q8_0' } else { 'f16' }), $p.ReserveMB)
  if ($p.Kmax -ge $layout.NLayers) { Write-TuneLog 'Model fits fully in VRAM -> full offload (no expert split needed).' }
  elseif ($gpu -and $plan.Kind -eq 'moe') { Write-TuneLog ("Max experts resident layers (estimate): K={0} (each layer keeps its experts on GPU)" -f $p.Kmax) }
  elseif ($gpu) { Write-TuneLog ("Dense model partial offload (estimate): ngl={0}" -f $p.Kmax) }
  else { Write-TuneLog 'CPU-only mode.' }
  if ($modelMB -gt $ramMB) { Write-TuneLog 'NOTE: model larger than RAM -> NVMe page cache tiering; close big apps while running for best speed.' }

  # 3b. commit budget (WDDM charges CUDA allocations to RAM+pagefile; unmounted pagefile -> false OOM)
  $mem = Get-TuneMemoryBudget
  Write-TuneLog ("Commit budget: {0} GB limit / {1} GB free  mounted=[{2}]" -f `
      [Math]::Round($mem.CommitLimitMB / 1024, 1), [Math]::Round($mem.CommitFreeMB / 1024, 1), ($mem.Mounted -join '; '))
  foreach ($w in @(Find-TuneMemoryWarning $modelMB $mem)) { Write-TuneLog ("WARNING: " + $w) }
  if ($FixPagefile) {
    if (@($mem.Missing).Count -eq 0) {
      Write-TuneLog 'No unmounted pagefile settings to fix.'
    } else {
      Write-TuneLog 'Re-registering unmounted pagefiles (explicit -FixPagefile opt-in)...'
      foreach ($l in @(Repair-TunePagefile $mem.Missing)) { Write-TuneLog ('  ' + $l) }
      Write-TuneLog 'REBOOT now, then re-run tune.cmd to revalidate under the restored commit budget.'
      Save-TuneLog $reportPath
      exit 0
    }
  }

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
  $cfgData = Read-TuneConfig $cfgPath
  $gpuSig = $(if ($gpu) { $gpu.Sig } else { 'cpu' })
  if (-not $SkipValidate -and $p.Kmax -gt 0 -and $gpu) {
    $cachedK = Get-TuneCachedK $cfgData $gpuSig $model $plan.NCtx
    if ((-not $Force) -and $cachedK -ge 0) {
      $Kbest = [Math]::Min($cachedK, $p.Kmax)
      Write-TuneLog ("Reusing validated K=$Kbest (hardware and model unchanged; use -Force to revalidate)")
    } else {
      $planArgBuilder = { param($k) Build-TuneArgs $plan $k }
      $vr = Find-BestTuneCtx $plan $p.Kmax $llamaExe $runtimeDir $planArgBuilder
      $Kbest = $vr.K
      Write-TuneLog ("Validated plan: ctx={0}  K={1} (hardware-picked, performance-verified)" -f $vr.NCtx, $Kbest)
    }
  }

  # 6. artifacts
  $bodies = New-TuneLauncherBodies $plan (Build-TuneArgs $plan $Kbest) $llamaExe
  Write-TuneLaunchers $startCmd $stopCmd $bodies $plan ([bool]$NoShortcut) $root
  $cfg = @{ ModelPath = $model; LlamaDir = $llamaDir; Port = $Port; K = $Kbest;
            Kind = $plan.Kind; NCtx = $plan.NCtx; KvQ8 = $plan.KvQ8; GpuSig = $gpuSig; TunedAt = (Get-Date).ToString('o') }
  Write-TuneConfig $cfgPath $cfg
  Write-TuneLog "Saved $cfgPath"
  Write-TuneLog '=== DONE. Use the desktop shortcuts (or start_llm.cmd). First requests are slower until page cache warms up. ==='
  Save-TuneLog $reportPath
} catch {
  Write-TuneLog ("ERROR: " + $_.Exception.Message)
  Write-TuneLog 'Fix the issue and re-run tune.cmd'
  Save-TuneLog $reportPath
  exit 1
}
