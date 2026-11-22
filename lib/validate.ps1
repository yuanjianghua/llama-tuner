# lib/validate.ps1 - real-launch validation: binary search the largest K that boots. ASCII-only.

function Test-TunePlan($plan, [string]$argline, [string]$llamaExe, [int]$loadTimeoutSec, [string]$runtimeDir) {
  Stop-TuneServer
  $errFile = Join-Path $runtimeDir 'try_err.log'
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  $p = Start-Process -FilePath $llamaExe -ArgumentList $argline -WindowStyle Minimized `
        -RedirectStandardError $errFile -PassThru
  $deadline = (Get-Date).AddSeconds($loadTimeoutSec)
  $ok = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($p.HasExited) { break }
    try {
      $h = Invoke-RestMethod ("http://127.0.0.1:{0}/health" -f $plan.Port) -TimeoutSec 3
      if ($h.status -eq 'ok') { $ok = $true; break }
    } catch {}
  }
  $res = @{ ok = $false; pp = 0; tg = 0; err = '' }
  if ($ok) {
    try {
      $body = @{ model = $plan.Alias
                 messages = @(@{ role = 'user'; content = 'Say the single word: ok' })
                 max_tokens = 8 } | ConvertTo-Json -Depth 5
      $r = Invoke-RestMethod ("http://127.0.0.1:{0}/v1/chat/completions" -f $plan.Port) `
            -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
      $res.ok = $true
      $res.pp = [Math]::Round($r.timings.prompt_per_second, 1)
      $res.tg = [Math]::Round($r.timings.predicted_per_second, 1)
    } catch { $res.err = $_.Exception.Message }
  }
  if (-not $res.ok) {
    try { $res.err = ((Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' | ') } catch {}
  }
  Stop-TuneServer
  return $res
}

# Returns @{ K = best-minus-headroom; LastMeas = $t }. K=0 means CPU-experts fallback.
# argBuilder is INJECTED ({ param($k) ... }) on purpose: this module must not know how the
# argument line is built (keeps validate decoupled from plan.ps1; testable with a fake builder).
function Find-BestTuneK($plan, [int]$Kmax, [string]$llamaExe, [string]$runtimeDir, [scriptblock]$argBuilder) {
  Write-TuneLog 'Validating with real launches (binary search, failures cost ~30s, each success ~1-2 min)...'
  Stop-TuneServer
  $lo = 0; $hi = $Kmax; $best = 0; $last = $null
  while ($lo -le $hi) {
    $mid = [int](($lo + $hi) / 2)
    $t = Test-TunePlan $plan (& $argBuilder $mid) $llamaExe 420 $runtimeDir
    if ($t.ok) { Write-TuneLog ("  K={0} OK  (pp {1} t/s, tg {2} t/s)" -f $mid, $t.pp, $t.tg); $best = $mid; $last = $t; $lo = $mid + 1 }
    else       { Write-TuneLog ("  K={0} FAILED: {1}" -f $mid, $t.err); $hi = $mid - 1 }
  }
  $kFinal = [Math]::Max(0, $best - 1)   # keep 1 layer headroom for KV growth / drivers
  if ($kFinal -ne $best) { Write-TuneLog "  -> keeping safety headroom: K=$kFinal" }
  return @{ K = $kFinal; LastMeas = $last }
}
