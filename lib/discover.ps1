# lib/discover.ps1 - locate model + llama.cpp, optional auto-download. ASCII-only.

function Find-TuneModel([string]$hint, [string]$cfgPath) {
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
  Write-TuneLog 'No GGUF model found (auto-search covers D:\Models, D:\Dev, C:\Users).'
  Write-TuneLog '  Beginner? Download a GGUF model first, e.g. https://huggingface.co/models?library=gguf'
  Write-TuneLog '  Mainland China mirror: https://modelscope.cn - pick a GGUF quantized file (Q4_K_M / Q4_K_XL are good starts),'
  Write-TuneLog '  then re-run:  tune.cmd -ModelPath X:\path\to\model.gguf'
  throw "No GGUF model found. Re-run with -ModelPath C:\path\to\model.gguf"
}

function Find-TuneLlama([string]$hint, [string]$cfgPath, [string]$root) {
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

function Install-TuneLlama([int]$gpuMB, [string]$root) {
  Write-TuneLog 'llama.cpp not found - downloading official Windows release from GitHub...'
  # PS5.1 on old .NET may negotiate TLS1.0 and fail GitHub's API; force modern TLS.
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
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
    Write-TuneLog ("  downloading " + $a.name)
    Invoke-WebRequest $a.browser_download_url -OutFile $z -TimeoutSec 1800
    $ex = Join-Path $tmp ('x_' + [IO.Path]::GetFileNameWithoutExtension($a.name))
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
    Expand-Archive $z -DestinationPath $ex -Force
    Copy-Item (Join-Path $ex '*') $dest -Recurse -Force
  }
  if (-not (Test-Path (Join-Path $dest 'llama-server.exe'))) { throw 'extract failed, no llama-server.exe' }
  Write-TuneLog 'NOTE for clean machines: CUDA/Vulkan builds need the VC++ 2015-2022 x64 runtime.'
  Write-TuneLog '  If llama-server fails with "VCRUNTIME140.dll not found", install it: https://aka.ms/vs/17/release/vc_redist.x64.exe'
  Write-TuneLog '  If GitHub downloads are slow/blocked: grab the zips from llama.cpp releases manually, unpack to one folder, re-run with -LlamaDir <folder>.'
  return $dest
}
