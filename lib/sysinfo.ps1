# lib/sysinfo.ps1 - hardware detection (pure query, no side effects). ASCII-only.

function Get-TuneRamMB {
  $os = Get-CimInstance Win32_OperatingSystem
  return [int]($os.TotalVisibleMemorySize / 1KB)
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

# caller MUST wrap in @() : a 0/1 element return gets unrolled by PS and scalar has no .Count on PS5.1
function Get-TuneGpuSummary {
  $gpus = @(Get-NvidiaGpus)
  if ($gpus.Count -eq 0) { return $null }
  return [pscustomobject]@{
    List    = $gpus
    TotalMB = ($gpus | Measure-Object -Property TotalMB -Sum).Sum
    UsedMB  = ($gpus | Measure-Object -Property UsedMB  -Sum).Sum
    Count   = $gpus.Count
    Sig     = (($gpus | ForEach-Object { "$($_.Name)/$($_.TotalMB)" }) -join '+')
  }
}
