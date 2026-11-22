# lib/plan.ps1 - pure planning/budget math. No I/O, no processes: unit-testable in tests/smoke.ps1. ASCII-only.

# digit-range regex for layer indices lo..hi, aligned to tens blocks so ranges
# spanning multiple tens (e.g. 100..125) stay correct: '10[0-9]|11[0-9]|12[0-5]'
function Make-LayerRegex([int]$lo, [int]$hi) {
  $parts = @()
  $i = $lo
  while ($i -le $hi) {
    $blockEnd = [Math]::Min($hi, [Math]::Floor($i / 10) * 10 + 9)
    $s = [string]$i; $e = [string]$blockEnd
    if ($s.Length -eq 1) {
      if ($i -eq $blockEnd) { $parts += $s } else { $parts += ('[' + $s + '-' + $e + ']') }
    } else {
      $t = $s.Substring(0, $s.Length - 1)
      $a = $s.Substring($s.Length - 1); $b = $e.Substring($e.Length - 1)
      if ($i -eq $blockEnd) { $parts += $s }
      elseif ($a -eq '0' -and $b -eq '9') { $parts += ($t + '[0-9]') }
      else { $parts += ($t + '[' + $a + '-' + $b + ']') }
    }
    $i = $blockEnd + 1
  }
  return ($parts -join '|')
}

function Build-TuneArgs($plan, [int]$K) {
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

# Inputs: modelMB, ramMB, layout (from Get-GgufLayout), gpu summary or $null, port, model path.
# Output: @{ Plan = hashtable; Kmax = int }
function New-TunePlan($model, [int]$modelMB, [int]$ramMB, $layout, $gpu, [int]$port) {
  $kvq8 = $modelMB -gt ($ramMB * 0.7)
  # context choice: KV bytes scale linearly with ctx; hybrid-SSM models have tiny KV, so size
  # ctx by the actual KV budget instead of a blanket 'big model -> 16k'. Largest of
  # {32768,16384,8192} whose KV fits 35% of free VRAM budget (with no GPU: old RAM heuristic).
  $perKMB = (2 * $layout.KvLayers * 1024 * $layout.KvHeads * $layout.HeadDim * $(if ($kvq8) { 1.06 } else { 2 })) / 1MB
  $nctx = if ($modelMB -gt $ramMB * 0.8) { 16384 } else { 32768 }
  if ($gpu) {
    $kvCapMB = ($gpu.TotalMB - $gpu.UsedMB - 650 * $gpu.Count) * 0.35
    foreach ($cand in @(32768, 16384, 8192)) {
      if (($perKMB * $cand / 1024) -le $kvCapMB) { $nctx = $cand; break }
    }
  }
  $kvMB = [int]($perKMB * $nctx / 1024)
  $nGpu = $(if ($gpu) { $gpu.Count } else { 1 })
  $reserveMB = 650 * $nGpu   # compute buffers + CUDA graphs + slack, per GPU

  $alias = ([regex]::Replace([IO.Path]::GetFileNameWithoutExtension($model), '[^A-Za-z0-9_.-]', '_')) -replace '\.gguf$',''
  if ($alias.Length -gt 32) { $alias = $alias.Substring(0, 32) }
  $plan = @{
    Model = $model; Alias = $alias; NCtx = $nctx; KvQ8 = $kvq8; Port = $port
    NLayers = $layout.NLayers
    Kind    = $(if (-not $gpu) { 'cpu' } elseif ($layout.IsMoE) { 'moe' } else { 'dense' })
    TensorSplit = $(if ($gpu -and $gpu.Count -gt 1) { ($gpu.List | ForEach-Object { $_.TotalMB }) -join ',' } else { '' })
  }

  $Kmax = 0
  if ($gpu) {
    $freeBudget = $gpu.TotalMB - $gpu.UsedMB - $reserveMB - $kvMB
    $usable = $freeBudget * 0.96
    if ($modelMB -le $usable) {
      $Kmax = $layout.NLayers
    } elseif ($layout.IsMoE) {
      $forExperts = $usable - ($layout.NonExpertBytes / 1MB)
      $Kmax = [Math]::Max(0, [Math]::Min($layout.NLayers - 1, [Math]::Floor($forExperts / $layout.PerLayerExpertMB)))
    } else {
      $Kmax = [Math]::Max(0, [Math]::Min($layout.NLayers, [Math]::Floor($usable / $layout.PerLayerExpertMB)))
    }
  }
  return @{ Plan = $plan; Kmax = [int]$Kmax; KVMB = $kvMB; ReserveMB = $reserveMB }
}

# Pure commit-budget check (unit-testable). Input: modelMB + budget from Get-TuneMemoryBudget.
# Output: array of warning strings (empty = healthy). The model must fit in the commit budget with
# headroom because WDDM charges GPU allocations to it; a pagefile that is configured but was not
# mounted this boot is a known failure mode that silently shrinks the budget.
function Find-TuneMemoryWarning([int]$modelMB, $budget) {
  $warn = @()
  if ([int]$budget.CommitLimitMB -lt ($modelMB + 2048)) {
    $warn += ('COMMIT BUDGET LOW: limit {0} GB < model {1} GB + 2 GB headroom -> WDDM cudaMalloc will false-OOM (VRAM may look free). Fix virtual memory (System > Advanced > Performance Settings > Advanced > Virtual memory), then reboot.' -f `
      [Math]::Round($budget.CommitLimitMB / 1024, 1), [Math]::Round($modelMB / 1024, 1))
  }
  foreach ($m in @($budget.Missing)) {
    $name = $(if ($m -is [string]) { $m } else { $m.Name })
    $warn += ('PAGEFILE NOT MOUNTED: ' + $name + ' is configured but absent this boot -> re-run as: tune.cmd -FixPagefile (as Administrator), then reboot.')
  }
  return $warn
}
