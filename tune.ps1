# llama-tuner: auto-tune llama.cpp launch config for THIS machine.
# ASCII-only source (safe on PS 5.1 with any codepage). Chinese labels use \u escapes.
# Usage:  tune.cmd            (detect -> validate by real runs -> write start/stop cmd + desktop shortcuts + report)
#         tune.ps1 -SkipValidate            (plan only, no test launches)
#         tune.ps1 -ModelPath D:\x\model.gguf -Port 8081
param(
  [string]$ModelPath = '',
  [string]$LlamaDir  = '',
  [int]$Port = 8080,
  [switch]$SkipValidate,
  [switch]$NoShortcut,
  [switch]$NoDownload,
  [switch]$Force,
  [switch]$Lib   # only define functions (for dot-sourcing in tests), do not run
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$cfgPath    = Join-Path $root 'config.json'
$reportPath = Join-Path $root 'tuning_report.txt'
$startCmd   = Join-Path $root 'start_llm.cmd'
$stopCmd    = Join-Path $root 'stop_llm.cmd'
$script:report = New-Object System.Collections.Generic.List[string]
function Say($m) { Write-Host $m; $script:report.Add($m) }

# ---------- helpers ----------
function Stop-Server {
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
}
function Get-NvidiaGpus {
  $smi = @(
    (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source,
    "$env:SystemRoot\System32\nvidia-smi.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $smi) { return @() }
  $out = @()
  try {
    $out = & $smi --query-gpu=index,name,memory.total,memory.used --format=csv,noheader,nounits 2>$null
  } catch { return @() }
  $gpus = @()
  foreach ($line in $out) {
    if ($line -match '^\s*\d+') {
      $p = $line -split ','
      $gpus += [pscustomobject]@{ Id = [int]$p[0].Trim(); Name = $p[1].Trim(); TotalMB = [int]$p[2].Trim(); UsedMB = [int]$p[3].Trim() }
    }
  }
  return $gpus
}
function Read-GgufStr($br) {
  $len = [int]$br.ReadUInt64()
  return [Text.Encoding]::UTF8.GetString($br.ReadBytes($len))
}
function Read-GgufValue($br, [int]$type, [int]$depth) {
  switch ($type) {
    0 { return $br.ReadByte() }
    1 { return $br.ReadSByte() }
    2 { return $br.ReadUInt16() }
    3 { return $br.ReadInt16() }
    4 { return $br.ReadUInt32() }
    5 { return $br.ReadInt32() }
    6 { return $br.ReadSingle() }
    7 { return ($br.ReadByte() -ne 0) }
    8 { return (Read-GgufStr $br) }
    9 {
      $elemType = $br.ReadInt32(); $count = [int]$br.ReadUInt64()
      $arr = @(); $cap = [Math]::Min($count, 64)
      for ($i = 0; $i -lt $count; $i++) {
        $v = Read-GgufValue $br $elemType ($depth + 1)
        if ($i -lt $cap) { $arr += $v }
      }
      return $arr
    }
    10 { return $br.ReadUInt64() }
    11 { return $br.ReadInt64() }
    12 { return $br.ReadDouble() }
    default { throw "gguf: unsupported value type $type" }
  }
}
function Parse-GgufHeader([string]$path) {
  Say "Parsing GGUF header: $path"
  $fs = [IO.File]::OpenRead($path)
  try {
    $br = New-Object IO.BinaryReader($fs)
    $magic = [Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
    if ($magic -ne 'GGUF') { throw "not a GGUF file: $path" }
    $version = $br.ReadInt32()
    $nTensors = $br.ReadUInt64()
    $nKv = [int]$br.ReadUInt64()
    $meta = @{}
    for ($i = 0; $i -lt $nKv; $i++) {
      $key = Read-GgufStr $br
      $type = $br.ReadInt32()
      $val = Read-GgufValue $br $type 0
      if (-not $meta.ContainsKey($key)) { $meta[$key] = $val }
    }
    $tensors = New-Object System.Collections.Generic.List[object]
    # tensor info: n_dims u32, dims u32[] or u64[] (newer v3 files use u64), dtype u32, offset u64.
    # Try 64-bit dims first; if any entry looks implausible, rewind and re-read with 32-bit dims.
    $tensorStart = $fs.Position
    foreach ($dimBits in @(64, 32)) {
      [void]$fs.Seek($tensorStart, 'Begin')
      $ok = $true
      $tensors.Clear()
      try {
        for ($i = 0; $i -lt $nTensors; $i++) {
          $name = Read-GgufStr $br
          if ($name.Length -lt 1 -or $name.Length -gt 200) { $ok = $false; break }
          $nDims = [int]$br.ReadUInt32()
          if ($nDims -lt 1 -or $nDims -gt 4) { $ok = $false; break }
          for ($d = 0; $d -lt $nDims; $d++) {
            $dim = if ($dimBits -eq 64) { $br.ReadUInt64() } else { [uint64]$br.ReadUInt32() }
            if ($dim -gt 1000000000) { $ok = $false; break }
          }
          if (-not $ok) { break }
          [void]$br.ReadUInt32()               # dtype (sizes inferred from offsets instead)
          $off = $br.ReadUInt64()
          $tensors.Add([pscustomobject]@{ Name = $name; Offset = $off })
        }
      } catch { $ok = $false }
      if ($ok -and $tensors.Count -eq $nTensors) { break }
    }
    if ($tensors.Count -ne $nTensors) { throw 'gguf: cannot parse tensor info (tried 64-bit and 32-bit dims)' }
    return @{ Version = $version; Tensors = $tensors; Meta = $meta }
  } finally { $fs.Dispose() }
}
function Find-Model([string]$hint) {
  if ($hint) { if (Test-Path $hint) { return (Resolve-Path $hint).Path } throw "model not found: $hint" }
  if (Test-Path $cfgPath) {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($c.ModelPath -and (Test-Path $c.ModelPath)) { return $c.ModelPath }
  }
  $roots = @('D:\Models', 'D:\Dev', 'C:\Users') | Where-Object { Test-Path $_ }
  foreach ($r in $roots) {
    $f = Get-ChildItem $r -Recurse -Filter *.gguf -ErrorAction SilentlyContinue |
         Where-Object { $_.Length -gt 1GB -and $_.Name -notmatch 'mmproj|lora' } |
         Sort-Object Length -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
  }
  throw "No GGUF model found. Re-run with -ModelPath C:\path\to\model.gguf"
}
function Find-Llama([string]$hint) {
  if ($hint -and (Test-Path (Join-Path $hint 'llama-server.exe'))) { return $hint }
  if (Test-Path $cfgPath) {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($c.LlamaDir -and (Test-Path (Join-Path $c.LlamaDir 'llama-server.exe'))) { return $c.LlamaDir }
  }
  $cands = @(
    'D:\Apps\llama',
    (Join-Path $root 'runtime\llama'),
    (Join-Path $env:LOCALAPPDATA 'llama'),
    'C:\Apps\llama'
  )
  foreach ($c in $cands) { if ($c -and (Test-Path (Join-Path $c 'llama-server.exe'))) { return $c } }
  return $null
}
function Install-Llama([int]$gpuMB) {
  Say 'llama.cpp not found - downloading official Windows release from GitHub...'
  $dest = Join-Path $root 'runtime\llama'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $rel = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' -TimeoutSec 30
  $pick = { param($pattern) $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1 }
  $main = $null; $cudart = $null
  if ($gpuMB -gt 0) {
    $main   = & $pick 'bin-win-cuda-cu12.*x64\.zip$'
    $cudart = & $pick 'cudart-llama-bin-win-cuda-12.*x64\.zip$'
  }
  if (-not $main) { $main = & $pick 'bin-win-vulkan-x64\.zip$' }
  if (-not $main) { $main = & $pick 'bin-win-cpu-x64\.zip$' }
  if (-not $main) { throw 'No usable release asset found. Download llama.cpp manually and pass -LlamaDir.' }
  $tmp = Join-Path $root 'runtime\zip'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  foreach ($a in @($main, $cudart) | Where-Object { $_ }) {
    $z = Join-Path $tmp $a.name
    Say ("  downloading " + $a.name)
    Invoke-WebRequest $a.browser_download_url -OutFile $z -TimeoutSec 1800
    $ex = Join-Path $tmp ('x_' + [IO.Path]::GetFileNameWithoutExtension($a.name))
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
    Expand-Archive $z -DestinationPath $ex -Force
    Copy-Item (Join-Path $ex '*') $dest -Recurse -Force
  }
  if (-not (Test-Path (Join-Path $dest 'llama-server.exe'))) { throw 'extract failed, no llama-server.exe' }
  return $dest
}
function Make-LayerRegex([int]$lo, [int]$hi) {
  # friendly digit-range regex for layer indices lo..hi, e.g. 8..47 -> 8|9|1[0-9]|[23][0-9]|4[0-7]
  $parts = @()
  $i = $lo
  while ($i -le $hi) {
    $span = if ($i -lt 10) { 1 } else { $pow = [Math]::Pow(10, ([string]$i).Length - 1); [int]$pow }
    $segStart = $i
    $segEnd = [Math]::Min($hi, $i + $span - 1)
    $s = [string]$segStart; $e = [string]$segEnd
    if ($s.Length -eq 1) {
      if ($segStart -eq $segEnd) { $parts += $s } else { $parts += ('[' + $s + '-' + $e + ']') }
    } else {
      $t = $s.Substring(0, $s.Length - 1)
      $a = $s.Substring($s.Length - 1); $b = $e.Substring($e.Length - 1)
      if ($segStart -eq $segEnd) { $parts += $s }
      elseif ($a -eq '0' -and $b -eq '9') { $parts += ($t + '[0-9]') }
      else { $parts += ($t + '[' + $a + '-' + $b + ']') }
    }
    $i = $segEnd + 1
  }
  return ($parts -join '|')
}
function Build-Args($plan, [int]$K) {
  $a = @('-m', ('"' + $plan.Model + '"'), '-fa', '1', '--jinja', '--metrics', '--ui',
         ('--alias ' + $plan.Alias), ('-c ' + $plan.NCtx), '-b', '8192', '-ub', '1024',
         '-np', '1', '--cache-reuse', '512')
  if ($plan.Kind -eq 'moe') {
    if ($K -ge $plan.NLayers) { $a += @('-ngl', '99') }
    elseif ($K -le 0)          { $a += @('-ngl', '99', ('-ot "_exps\.' + '=' + 'CPU"')) }
    else {
      $rx = 'blk\.(' + (Make-LayerRegex $K ($plan.NLayers - 1)) + ')\..*_exps\.=CPU'
      $a += @('-ngl', '99', ('-ot "' + $rx + '"'))
    }
  } elseif ($plan.Kind -eq 'dense') {
    $ngl = [Math]::Min($K, $plan.NLayers); if ($ngl -lt 0) { $ngl = 0 }
    $a += @('-ngl', $ngl)
  } else { $a += @('-ngl', '0') }
  if ($plan.KvQ8) { $a += @('-ctk', 'q8_0', '-ctv', 'q8_0') }
  if ($plan.TensorSplit) { $a += @('--tensor-split', $plan.TensorSplit) }
  $a += @('--port', $plan.Port)
  return ($a -join ' ')
}
function Test-Plan([string]$argline, [int]$loadTimeoutSec) {
  Stop-Server
  $errFile = Join-Path $root 'runtime\try_err.log'
  New-Item -ItemType Directory -Force -Path (Split-Path $errFile) | Out-Null
  $p = Start-Process -FilePath $script:llamaExe -ArgumentList $argline -WindowStyle Minimized `
        -RedirectStandardError $errFile -PassThru
  $deadline = (Get-Date).AddSeconds($loadTimeoutSec)
  $ok = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($p.HasExited) { break }
    try {
      $h = Invoke-RestMethod ("http://127.0.0.1:{0}/health" -f $script:plan.Port) -TimeoutSec 3
      if ($h.status -eq 'ok') { $ok = $true; break }
    } catch {}
  }
  $res = @{ ok = $false; pp = 0; tg = 0; err = '' }
  if ($ok) {
    try {
      $body = @{ model = $script:plan.Alias
                 messages = @(@{ role = 'user'; content = 'Say the single word: ok' })
                 max_tokens = 8 } | ConvertTo-Json -Depth 5
      $r = Invoke-RestMethod ("http://127.0.0.1:{0}/v1/chat/completions" -f $script:plan.Port) `
            -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
      $res.ok = $true
      $res.pp = [Math]::Round($r.timings.prompt_per_second, 1)
      $res.tg = [Math]::Round($r.timings.predicted_per_second, 1)
    } catch { $res.err = $_.Exception.Message }
  }
  if (-not $res.ok) {
    try { $res.err = ((Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' | ') } catch {}
  }
  Stop-Server
  return $res
}
function Write-Launchers($plan, [int]$K) {
  $argLine = Build-Args $plan $K
  $health = "try{$$h=Invoke-RestMethod http://127.0.0.1:{0}/health -TimeoutSec 2; if($$h.status -eq 'ok'){exit 10}}catch{}; exit 0" -f $plan.Port
  $waith  = "try{$$h=Invoke-RestMethod http://127.0.0.1:{0}/health -TimeoutSec 3; if($$h.status -eq 'ok'){exit 0}}catch{}; exit 1" -f $plan.Port
  $startBody = @"
@echo off
title Start LLM
powershell -NoProfile -Command "$health"
if %errorlevel%==10 goto open
echo Starting llama-server (auto-tuned for this machine). Loading model, please wait...
start "llama-server" /min "$($script:llamaExe)" $argLine
:waitloop
timeout /t 3 /nobreak >nul
powershell -NoProfile -Command "$waith"
if errorlevel 1 goto waitloop
:open
start http://localhost:$($plan.Port)/
"@
  $stopBody = @"
@echo off
title Stop LLM
taskkill /im llama-server.exe /f >nul 2>&1
echo llama-server stopped.
timeout /t 2
"@
  Set-Content -Path $startCmd -Value $startBody -Encoding ASCII
  Set-Content -Path $stopCmd  -Value $stopBody  -Encoding ASCII
  Say "Wrote $startCmd"
  Say "Wrote $stopCmd"
  if ($NoShortcut) { return }
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  # CN labels via unicode escapes: 启动 = qi-dong, 停止 = ting-zhi
  $lnkStart = Join-Path $desktop (([regex]::Unescape('\u542f\u52a8')) + 'LLM.lnk')
  $lnkStop  = Join-Path $desktop (([regex]::Unescape('\u505c\u6b62'))  + 'LLM.lnk')
  $sc = $ws.CreateShortcut($lnkStart)
  $sc.TargetPath = $startCmd; $sc.WorkingDirectory = $root
  $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
  $sc.Description = 'Start auto-tuned llama-server'; $sc.Save()
  $sc2 = $ws.CreateShortcut($lnkStop)
  $sc2.TargetPath = $stopCmd; $sc2.WorkingDirectory = $root
  $sc2.IconLocation = "$env:SystemRoot\System32\shell32.dll,132"
  $sc2.Description = 'Stop llama-server'; $sc2.Save()
  Say "Desktop shortcuts created: $lnkStart ; $lnkStop"
}

if ($Lib) { return }

# ---------- main ----------
try {
  Say "=== llama-tuner $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
  # a running server would poison VRAM/RAM readings and validation runs
  if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Say 'Stopping running llama-server for clean measurement...'
    Stop-Server
  }
  # detect RAM
  $os = Get-CimInstance Win32_OperatingSystem
  $ramMB = [int]($os.TotalVisibleMemorySize / 1KB)
  Say ("RAM total: {0} GB" -f [Math]::Round($ramMB / 1024, 1))
  # detect GPU(s)
  $gpus = @(Get-NvidiaGpus)
  $gpu = $null
  if ($gpus.Count -gt 0) {
    $gpu = @{
      TotalMB = ($gpus | Measure-Object -Property TotalMB -Sum).Sum
      UsedMB  = ($gpus | Measure-Object -Property UsedMB  -Sum).Sum
      Count   = $gpus.Count
    }
    Say ("GPU x{0}: {1}" -f $gpus.Count, (($gpus | ForEach-Object { "$($_.Name) $($_.TotalMB)MB (used $($_.UsedMB)MB)" }) -join '; '))
    if ($gpus.Count -gt 1) { Say 'Multi-GPU: VRAM budgets aggregated; per-GPU overhead reserved; tensor-split proportional to card size will be emitted. Cross-card sync runs over PCIe, so gains are sub-linear.' }
  } else {
    Say 'GPU: no NVIDIA GPU detected -> CPU-only plan (AMD/Vulkan users: tune manually)'
  }

  $model = Find-Model $ModelPath
  $modelMB = [Math]::Round((Get-Item $model).Length / 1MB)
  Say "Model: $model  ($([Math]::Round($modelMB/1024,2)) GiB)"

  $hdr = Parse-GgufHeader $model
  $arch = [string]$hdr.Meta['general.architecture']
  $nLayers = [int]$hdr.Meta["$arch.block_count"]
  if (-not $nLayers) { $nLayers = [int]$hdr.Meta['llama.block_count'] }
  if (-not $nLayers) { throw "cannot find block_count for arch '$arch'" }
  $kvh = [int]$hdr.Meta["$arch.attention.head_count_kv"]; if (-not $kvh) { $kvh = 4 }
  $heads = [int]$hdr.Meta["$arch.attention.head_count"]; if (-not $heads) { $heads = 32 }
  $embd = [int]$hdr.Meta["$arch.embedding_length"]; if (-not $embd) { $embd = 4096 }
  $hd = [int]$hdr.Meta["$arch.attention.key_length"]
  if (-not $hd) { $hd = [Math]::Floor($embd / $heads) }
  $isMoeMeta = [int]$hdr.Meta["$arch.expert_count"] -gt 1
  $faInt = [int]$hdr.Meta["$arch.full_attention_interval"]; if (-not $faInt -or $faInt -lt 1) { $faInt = 1 }
  $kvLayers = [int][Math]::Ceiling($nLayers / $faInt)
  Say ("Arch: $arch  layers=$nLayers (kv layers=$kvLayers, full_attn_interval=$faInt)  kv_heads=$kvh  head_dim=$hd  experts=$isMoeMeta")

  # tensor layout: sizes inferred from sorted offsets
  $ts = $hdr.Tensors | Sort-Object Offset
  $expertBytes = [double]0; $nonExpertBytes = [double]0
  $perLayerExpert = @{}
  for ($i = 0; $i -lt $ts.Count; $i++) {
    $size = if ($i -lt $ts.Count - 1) { $ts[$i + 1].Offset - $ts[$i].Offset } else { 0 }
    $m = [regex]::Match($ts[$i].Name, 'blk\.(\d+)\.')
    if ($ts[$i].Name -match '_exps\.') {
      $expertBytes += $size
      if ($m.Success) {
        $L = [int]$m.Groups[1].Value
        if (-not $perLayerExpert.ContainsKey($L)) { $perLayerExpert[$L] = [double]0 }
        $perLayerExpert[$L] += $size
      }
    } else { $nonExpertBytes += $size }
  }
  $isMoE = ($expertBytes -gt 0 -and $perLayerExpert.Count -gt 0)
  if ($expertBytes -lt 0 -or $nonExpertBytes -lt 0 -or ($expertBytes + $nonExpertBytes) -gt $modelMB * 2MB) {
    throw 'gguf: tensor size accounting failed (offset sort/parse issue)'
  }
  $perLayerExpertMB = if ($isMoE) { $expertBytes / $nLayers / 1MB } else { $modelMB * 1MB / $nLayers / 1MB }
  Say ("MoE experts: {0} GB total, ~{1:N0} MB/layer; non-expert weights: {2} GB" -f `
      [Math]::Round($expertBytes / 1GB, 2), $perLayerExpertMB, [Math]::Round($nonExpertBytes / 1GB, 2))

  # context + KV budget
  $nctx = if ($modelMB -gt $ramMB * 0.8) { 16384 } else { 32768 }
  $kvq8 = $modelMB -gt ($ramMB * 0.7)
  $kvMB = [int]((2 * $kvLayers * $nctx * $kvh * $hd * $(if ($kvq8) { 1.06 } else { 2 })) / 1MB)
  $nGpu = $(if ($gpu) { $gpu.Count } else { 1 })
  $reserveMB = 650 * $nGpu   # compute buffers + CUDA graphs + slack, per GPU
  Say ("Plan ctx={0}  KV={1} MB ({2})  gpu reserve={3} MB" -f $nctx, $kvMB, $(if ($kvq8) { 'q8_0' } else { 'f16' }), $reserveMB)

  $alias = ([regex]::Replace([IO.Path]::GetFileNameWithoutExtension($model), '[^A-Za-z0-9_.-]', '_')) -replace '\.gguf$',''
  if ($alias.Length -gt 32) { $alias = $alias.Substring(0, 32) }
  $plan = @{ Model = $model; Alias = $alias; NCtx = $nctx; KvQ8 = $kvq8; Port = $Port;
             NLayers = $nLayers; Kind = $(if ($isMoE) { 'moe' } elseif ($gpu) { 'dense' } else { 'cpu' });
             TensorSplit = $(if ($gpu -and $gpu.Count -gt 1) { ($gpus | ForEach-Object { $_.TotalMB }) -join ',' } else { '' }) }

  $Kmax = 0
  if ($gpu) {
    $freeBudget = $gpu.TotalMB - $gpu.UsedMB - $reserveMB - $kvMB
    $usable = $freeBudget * 0.96
    if ($modelMB -le $usable) {
      $Kmax = $nLayers; Say 'Model fits fully in VRAM -> full offload (no expert split needed).'
    } elseif ($isMoE) {
      $forExperts = $usable - ($nonExpertBytes / 1MB)
      $Kmax = [Math]::Max(0, [Math]::Min($nLayers - 1, [Math]::Floor($forExperts / $perLayerExpertMB)))
      Say ("Max experts resident layers (estimate): K=$Kmax (each layer keeps its experts on GPU)")
    } else {
      $Kmax = [Math]::Max(0, [Math]::Min($nLayers, [Math]::Floor($usable / $perLayerExpertMB)))
      Say ("Dense model partial offload (estimate): ngl=$Kmax")
    }
  } else { $Kmax = 0; Say 'CPU-only mode.' }
  if ($modelMB -gt $ramMB) { Say 'NOTE: model larger than RAM -> NVMe page cache tiering; close big apps while running for best speed.' }

  # validate downward (binary search max K that actually boots)
  $script:llamaExeDir = Find-Llama $LlamaDir
  if (-not $script:llamaExeDir) {
    if ($NoDownload) { throw 'llama-server.exe not found and -NoDownload set.' }
    $script:llamaExeDir = Install-Llama $(if ($gpu) { $gpu.TotalMB } else { 0 })
  }
  $script:llamaExe = Join-Path $script:llamaExeDir 'llama-server.exe'
  Say "llama.cpp: $script:llamaExeDir"
  $script:plan = $plan

  $Kbest = $Kmax; $meas = $null
  if (-not $SkipValidate -and $Kmax -gt 0 -and $gpu) {
    Say 'Validating with real launches (binary search, failures cost ~30s, each success ~1-2 min)...'
    Stop-Server
    $lo = 0; $hi = $Kmax; $best = 0
    while ($lo -le $hi) {
      $mid = [int](($lo + $hi) / 2)
      $t = Test-Plan (Build-Args $plan $mid) 420
      if ($t.ok) { Say ("  K={0} OK  (pp {1} t/s, tg {2} t/s)" -f $mid, $t.pp, $t.tg); $best = $mid; $meas = $t; $lo = $mid + 1 }
      else       { Say ("  K={0} FAILED: {1}" -f $mid, $t.err); $hi = $mid - 1 }
    }
    $Kbest = [Math]::Max(0, $best - 1)   # keep 1 layer headroom for KV growth / drivers
    if ($Kbest -ne $best) { Say "  -> keeping safety headroom: K=$Kbest" }
  }

  Write-Launchers $plan $Kbest
  $cfg = @{ ModelPath = $model; LlamaDir = $script:llamaExeDir; Port = $Port; K = $Kbest;
            Kind = $plan.Kind; NCtx = $nctx; KvQ8 = $kvq8; TunedAt = (Get-Date).ToString('o') }
  Set-Content -Path $cfgPath -Value ($cfg | ConvertTo-Json) -Encoding ASCII
  Say "Saved $cfgPath"
  Say '=== DONE. Use the desktop shortcuts (or start_llm.cmd). First requests are slower until page cache warms up. ==='
} catch {
  Say ("ERROR: " + $_.Exception.Message)
  Say 'Fix the issue and re-run tune.cmd'
  $script:report | Set-Content -Path $reportPath -Encoding UTF8
  exit 1
}
$script:report | Set-Content -Path $reportPath -Encoding UTF8
