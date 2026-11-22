# tests/smoke.ps1 - OFFLINE behavior regression suite (no model loading, no server, no network).
# Run:  powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 [-GgufPath D:\path\model.gguf]
# Architecture/coupling audit lives in tests/arch.ps1. Exit code 0 = all pass.
param([string]$GgufPath = 'D:\Models\LLM\qwen36-UD-Q4_K_XL\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\load.ps1')
foreach ($mp in Get-TuneModulePaths $root) { . $mp }

$script:pass = 0
$script:failList = @()
function Assert-Ok([bool]$cond, [string]$name) {
  if ($cond) { $script:pass++; Write-Host ('PASS  ' + $name) }
  else { $script:failList += $name; Write-Host ('FAIL  ' + $name) }
}

# ---------- 1. layer-range regex must match EXACTLY the intended layer set ----------
# (regression: old algorithm broke on ranges spanning multiple tens, e.g. 100..125)
foreach ($range in @(@(8,47), @(6,40), @(0,40), @(0,7), @(9,11), @(39,40), @(7,7), @(100,125), @(0,127), @(2,5))) {
  $lo = $range[0]; $hi = $range[1]
  # NOTE: the alternation MUST be wrapped in a group, otherwise 'blk\.' only guards the first branch
  $pat = 'blk\.(' + (Make-LayerRegex $lo $hi) + ')\..*_exps\.'
  $bad = @()
  foreach ($L in 0..149) {
    $name = ('blk.' + $L + '.ffn_gate_exps.weight')
    $in = ($L -ge $lo -and $L -le $hi)
    if (($name -match $pat) -ne $in) { $bad += $L }
  }
  Assert-Ok ($bad.Count -eq 0) ('Make-LayerRegex ' + $lo + '..' + $hi + ' exact match set' + $(if ($bad.Count) { ' (wrong: ' + ($bad -join ',') + ')' } else { '' }))
}

# ---------- 2. Build-TuneArgs ----------
$planMoe = @{ Model = 'D:\m\model.gguf'; Alias = 'model'; NCtx = 16384; KvQ8 = $true; Port = 8080;
              NLayers = 41; Kind = 'moe'; TensorSplit = '' }
$args6 = Build-TuneArgs $planMoe 6
Assert-Ok ($args6 -match '-ngl 99') 'moe K=6 keeps -ngl 99'
Assert-Ok ($args6 -match '-ot "blk\\.') 'moe K=6 emits expert offload regex'
$rxm = [regex]::Match($args6, '-ot "([^"]+)"')
$okRx = $rxm.Success
# llama.cpp splits the -ot value at the final '=' : regex part vs 'CPU' directive
$embedded = if ($okRx) { $rxm.Groups[1].Value -replace '=CPU$', '' } else { 'zzz' }
Assert-Ok ($okRx -and ('blk.6.x.ffn_down_exps.weight' -match $embedded)) 'embedded regex matches first resident layer'
Assert-Ok ($okRx -and -not ('blk.5.x.ffn_down_exps.weight' -match $embedded)) 'embedded regex rejects evicted layer'
Assert-Ok ($okRx -and ('blk.40.x.ffn_down_exps.weight' -match $embedded)) 'embedded regex matches last layer'
Assert-Ok ($args6 -match '-ctk q8_0 -ctv q8_0') 'moe K=6 kv quant flags'
Assert-Ok ($args6 -match '--cache-reuse 512' -and $args6 -match '-np 1') 'prefix-cache flags present'
Assert-Ok ($args6.TrimEnd() -match '--port 8080$') 'port last'
$argsFull = Build-TuneArgs $planMoe 41
Assert-Ok ($argsFull -match '-ngl 99' -and $argsFull -notmatch '-ot') 'moe K=NLayers -> full offload, no -ot'
$argsZero = Build-TuneArgs $planMoe 0
Assert-Ok ($argsZero -match '-ot "_exps') 'moe K=0 -> all experts to CPU'
$planDense = @{ Model = 'D:\m\d.gguf'; Alias = 'd'; NCtx = 32768; KvQ8 = $false; Port = 8080; NLayers = 32; Kind = 'dense'; TensorSplit = '' }
$argsD = Build-TuneArgs $planDense 20
Assert-Ok ($argsD -match '-ngl 20' -and $argsD -notmatch '-ot') 'dense uses -ngl only'
$planCpu = @{ Model = 'D:\m\c.gguf'; Alias = 'c'; NCtx = 16384; KvQ8 = $true; Port = 8081; NLayers = 41; Kind = 'cpu'; TensorSplit = '' }
Assert-Ok ((Build-TuneArgs $planCpu 0) -match '-ngl 0') 'cpu plan -ngl 0'
$planSplit = $planMoe.Clone(); $planSplit.TensorSplit = '8151,8151'
Assert-Ok ((Build-TuneArgs $planSplit 10) -match '--tensor-split 8151,8151') 'multi-gpu tensor-split emitted'

# ---------- 3. New-TunePlan budget math (pins current coefficients) ----------
$layout = [pscustomobject]@{ NLayers = 41; KvLayers = 11; KvHeads = 2; HeadDim = 256; IsMoE = $true
  ExpertBytes = [double](18.74 * 1GB); NonExpertBytes = [double](2.53 * 1GB); PerLayerExpertMB = [double]468 }
$gpu1 = [pscustomobject]@{ Count = 1; TotalMB = 8151; UsedMB = 980
  List = @([pscustomobject]@{ TotalMB = 8151 }) }
$p1 = New-TunePlan 'D:\m\model.gguf' 21790 15760 $layout $gpu1 8080
Assert-Ok ($p1.KVMB -eq 187) ('KV budget = 187 MB (got ' + $p1.KVMB + ', hybrid-SSM 11 kv layers)')
Assert-Ok ($p1.Kmax -eq 7) ('single 8GB card Kmax = 7 (got ' + $p1.Kmax + ')')
$gpu2 = [pscustomobject]@{ Count = 2; TotalMB = 16302; UsedMB = 1960
  List = @([pscustomobject]@{ TotalMB = 8151 }, [pscustomobject]@{ TotalMB = 8151 }) }
$p2 = New-TunePlan 'D:\m\model.gguf' 21790 15760 $layout $gpu2 8080
Assert-Ok ($p2.Kmax -eq 20) ('dual 8GB cards Kmax = 20 (got ' + $p2.Kmax + ')')
Assert-Ok ($p2.Plan.TensorSplit -eq '8151,8151') 'tensor-split from card sizes'
$layoutD = [pscustomobject]@{ NLayers = 32; KvLayers = 32; KvHeads = 8; HeadDim = 128; IsMoE = $false
  ExpertBytes = [double]0; NonExpertBytes = [double](8 * 1GB); PerLayerExpertMB = [double]250 }
$p3 = New-TunePlan 'D:\m\d.gguf' 8000 15760 $layoutD $gpu1 8080
Assert-Ok ($p3.Plan.Kind -eq 'dense' -and $p3.Kmax -eq 9) ('dense partial offload Kmax = 9 (got ' + $p3.Kmax + ')')
$p4 = New-TunePlan 'D:\m\c.gguf' 21790 15760 $layout $null 8080
Assert-Ok ($p4.Plan.Kind -eq 'cpu' -and $p4.Kmax -eq 0) 'no gpu -> cpu plan K=0'

# ---------- 4. GGUF parsing: synthetic u64-dims and u32-dims files ----------
$tmpDir = Join-Path $env:TEMP 'llama-tuner-tests'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$enc = New-Object Text.UTF8Encoding($false)
function New-MiniGguf([string]$outPath, [bool]$dim64) {
  $ms = New-Object IO.MemoryStream
  $w = New-Object IO.BinaryWriter($ms, $enc)
  $w.Write([Text.Encoding]::ASCII.GetBytes('GGUF'))
  $w.Write([int32]3)
  $w.Write([uint64]2)   # n_tensors
  $w.Write([uint64]1)   # n_kv
  $kb = $enc.GetBytes('general.architecture'); $w.Write([uint64]$kb.Length); $w.Write($kb)
  $w.Write([int32]8)
  $vb = $enc.GetBytes('qwen35moe'); $w.Write([uint64]$vb.Length); $w.Write($vb)
  $offs = @(0, 4096)
  $names = @('output.weight', 'blk.0.ffn_gate_exps.weight')
  for ($i = 0; $i -lt 2; $i++) {
    $nb = $enc.GetBytes($names[$i]); $w.Write([uint64]$nb.Length); $w.Write($nb)
    $w.Write([uint32]2)
    if ($dim64) { $w.Write([uint64]4096); $w.Write([uint64]5120) }
    else        { $w.Write([uint32]4096); $w.Write([uint32]5120) }
    $w.Write([uint32]8)                  # dtype
    $w.Write([uint64]$offs[$i])
  }
  $w.Flush(); [IO.File]::WriteAllBytes($outPath, $ms.ToArray()); $w.Dispose(); $ms.Dispose()
}
foreach ($dim64 in @($true, $false)) {
  $f = Join-Path $tmpDir $(if ($dim64) { 'mini_u64.gguf' } else { 'mini_u32.gguf' })
  New-MiniGguf $f $dim64
  $tag = $(if ($dim64) { 'u64 (new v3)' } else { 'u32 (old v3, exercises rewind)' })
  try {
    $h = Parse-GgufHeader $f
    Assert-Ok ($h.Tensors.Count -eq 2 -and $h.Tensors[0].Name -eq 'output.weight' -and
               [uint64]$h.Tensors[1].Offset -eq 4096 -and $h.Meta['general.architecture'] -eq 'qwen35moe') ('parse GGUF dims=' + $tag)
  } catch { Assert-Ok $false ('parse GGUF dims=' + $tag + ' threw: ' + $_.Exception.Message) }
  # truncated file must throw, not hang or return garbage
  $bytes = [IO.File]::ReadAllBytes($f)
  $t = Join-Path $tmpDir 'mini_trunc.gguf'
  [IO.File]::WriteAllBytes($t, $bytes[0..([int]($bytes.Length * 0.6))])
  $threw = $false
  try { [void](Parse-GgufHeader $t) } catch { $threw = $true }
  Assert-Ok $threw ('truncated GGUF throws (dims=' + $tag + ')')
}

# ---------- 5. real model (dev machine); skipped elsewhere ----------
if (Test-Path $GgufPath) {
  try {
    $hdr = Parse-GgufHeader $GgufPath
    $lay = Get-GgufLayout $hdr (Get-Item $GgufPath).Length
    Assert-Ok ($lay.NLayers -eq 41 -and $lay.KvLayers -eq 11 -and $lay.HeadDim -eq 256 -and
               $lay.KvHeads -eq 2 -and $lay.IsMoE) 'real model layout facts (41L/11KV/256hd/2kvh/moe)'
    Assert-Ok ($lay.PerLayerExpertMB -gt 400 -and $lay.PerLayerExpertMB -lt 550) ('per-layer expert MB in [400,550] (got ' + [Math]::Round($lay.PerLayerExpertMB) + ')')
  } catch { Assert-Ok $false ('real model parse: ' + $_.Exception.Message) }
} else {
  Write-Host ('SKIP  real model test (not found: ' + $GgufPath + ')')
}

# ---------- 6. launcher bodies (regressions for the 3 cmd-generation bugs) ----------
$b = New-TuneLauncherBodies $planMoe (Build-TuneArgs $planMoe 6) 'C:\x\llama-server.exe'
$s = $b.Start
Assert-Ok ($s.Contains('$h=Invoke-RestMethod http://127.0.0.1:8080/health')) 'health check has literal $h (not $$ expansion)'
Assert-Ok ($s.Contains('{exit 10}') -and $s.Contains('{exit 0}')) 'literal braces survive (-f format bug regression)'
Assert-Ok (-not $s.Contains('$$h')) 'no $$ in launcher'
Assert-Ok ($s.Contains('ping -n 4 127.0.0.1') -and -not $s.Contains('timeout /t')) 'ping sleep, no timeout stdin dependency'
Assert-Ok ($s.Contains('tasklist /fi "imagename eq llama-server.exe"') -and $s.Contains('exited during loading')) 'wait loop has dead-process watchdog (regression: infinite wait when load fails)'
Assert-Ok ($s.Contains('-ot "blk\.')) 'launcher carries expert offload regex'
Assert-Ok ($b.Stop.Contains('taskkill /im llama-server.exe /f')) 'stop script kills server'

# ---------- 7. Find-BestTuneK binary search (Test-TunePlan + Stop-TuneServer stubbed;
#             never touches the live server or starts processes here) ----------
function Stop-TuneServer { }
function Test-TunePlan($plan, [string]$argline, [string]$llamaExe, [int]$loadTimeoutSec, [string]$runtimeDir) {
  $k = [int][regex]::Match($argline, '-K (\d+)').Groups[1].Value
  $script:kTried += $k
  if ($k -le $script:kTrueMax) { return @{ ok = $true; pp = 10; tg = 10; err = '' } }
  return @{ ok = $false; pp = 0; tg = 0; err = 'simulated load failure' }
}
$kb = { param($k) ('-K ' + $k) }
$script:kTrueMax = 7; $script:kTried = @()
$r1 = Find-BestTuneK @{ Alias = 'x'; Port = 8080 } 10 'fake.exe' 'rt' $kb
Assert-Ok ($r1.K -eq 6) ('search: true max 7 -> safety headroom K=6 (got ' + $r1.K + ')')
Assert-Ok ((($script:kTried | Sort-Object -Unique) -join ',') -eq '5,6,7,8') ('search probes the right points (tried ' + (($script:kTried | Sort-Object -Unique) -join ',') + ')')
$script:kTrueMax = -1; $script:kTried = @()
$r2 = Find-BestTuneK @{ Alias = 'x'; Port = 8080 } 5 'fake.exe' 'rt' $kb
Assert-Ok ($r2.K -eq 0) ('all launches fail -> K=0 fallback (got ' + $r2.K + ')')
$script:kTrueMax = 3; $script:kTried = @()
$r3 = Find-BestTuneK @{ Alias = 'x'; Port = 8080 } 3 'fake.exe' 'rt' $kb
Assert-Ok ($r3.K -eq 2 -and $script:kTried.Count -le 3) ('everything fits -> K=Kmax-1 in few probes (K=' + $r3.K + ', probes=' + $script:kTried.Count + ')')

# ---------- summary ----------
Write-Host ''
Write-Host ('=== smoke: ' + $script:pass + ' passed, ' + $script:failList.Count + ' failed ===')
if ($script:failList.Count -gt 0) { $script:failList | ForEach-Object { Write-Host ('  FAILED: ' + $_) }; exit 1 }
exit 0
