# lib/sysinfo.ps1 - hardware detection (pure query, no side effects). ASCII-only.
# NOTE: "no side effects" covers registry/CIM *writes*; the Repair-TunePagefile sibling function at
# the bottom is the single sanctioned exception (explicit -FixPagefile opt-in from the entry only),
# so the pagefile fix ships in the same zero-dependency PowerShell file the tests already load.

function Get-TuneRamMB {
  $os = Get-CimInstance Win32_OperatingSystem
  return [int]($os.TotalVisibleMemorySize / 1KB)
}

# Windows commit budget = RAM + mounted pagefiles. WDDM charges every CUDA allocation against it,
# so an unmounted pagefile -> low commit limit -> cudaMalloc "out of memory" with VRAM free to spare
# (field incident 2026-11-22: D:\pagefile.sys configured but not mounted after reboot, limit fell
#  47 -> 17 GB, model load false-OOM'd at 7 GB free VRAM).
# caller MUST wrap in @() on PS5.1 for the array fields.
function Get-TuneMemoryBudget {
  $os = Get-CimInstance Win32_OperatingSystem
  $mounted = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $configured = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  # match by drive letter (case differs between the two CIM classes)
  $missing = @($configured | Where-Object { $cf = $_; -not @($mounted | Where-Object { $_.Substring(0, 2) -ieq $cf.Substring(0, 2) }).Count })
  return [pscustomobject]@{
    CommitLimitMB = [int]($os.TotalVirtualMemorySize / 1KB)   # RAM + mounted pagefiles
    CommitFreeMB  = [int]($os.FreeVirtualMemory / 1KB)
    Mounted       = $mounted
    Missing       = $missing                                  # configured but absent this boot
  }
}

# Explicit opt-in repair (entry calls it only with -FixPagefile; needs admin). Re-registers each
# configured-but-not-mounted pagefile setting (delete stale entry + recreate) so the next boot
# mounts it - the exact manual fix that cured the 2026-11-22 false-OOM on this machine.
function Repair-TunePagefile($missing) {
  $log = @()
  foreach ($m in @($missing)) {
    $name = $(if ($m -is [string]) { $m } else { $m.Name })
    $drv  = $name.Substring(0, 2)
    $init = $(if ($m -isnot [string] -and $m.InitialSize -gt 0) { [uint32]$m.InitialSize } else { [uint32]16384 })
    $max  = $(if ($m -isnot [string] -and $m.MaximumSize -gt 0) { [uint32]$m.MaximumSize } else { [uint32]16384 })
    try {
      foreach ($s in @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name.Substring(0, 2) -ieq $drv })) {
        Remove-CimInstance -InputObject $s -ErrorAction SilentlyContinue
      }
      New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $name; InitialSize = $init; MaximumSize = $max } -ErrorAction Stop | Out-Null
      $log += ('re-registered ' + $name + ' (' + $init + '/' + $max + ' MB) - REBOOT to mount it')
    } catch {
      $log += ('FAILED to re-register ' + $name + ': ' + $_.Exception.Message.Split("`n")[0] + '  (run tune as Administrator)')
    }
  }
  return $log
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

# Clean-machine trap: an NVIDIA GPU whose driver is NOT installed does not appear in nvidia-smi,
# and the tuner would silently plan a CPU-only run 10x slower than the hardware allows.
# Detect the silicon at the PnP layer (VEN_10DE = NVIDIA) so we can tell the user to install the driver.
function Test-TuneNvidiaDevicePresent {
  @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -ErrorAction SilentlyContinue |
      Where-Object { $_.DeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA|GeForce|RTX|GTX' }).Count -gt 0
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
