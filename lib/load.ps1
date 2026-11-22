# lib/load.ps1 - manifest-driven module loader. The ONLY place module wiring happens at runtime:
# order and dependencies come from lib/modules.json (verified statically by tests/arch.ps1).
# Usage (entry scripts):  . lib\load.ps1 ; foreach ($mp in Get-TuneModulePaths $root) { . $mp }
# ASCII-only source.

function Get-TuneManifest([string]$root) {
  $mf = Join-Path $root 'lib\modules.json'
  if (-not (Test-Path $mf)) { throw "missing module manifest: $mf" }
  $obj = Get-Content $mf -Raw | ConvertFrom-Json
  return @($obj.modules)
}

# Returns module file paths in safe load order; fails fast when a module lists a dependency
# that was not declared earlier in the manifest (catches manifest typos/reordering at startup).
function Get-TuneModulePaths([string]$root) {
  $loaded = @{}
  $paths = @()
  foreach ($m in (Get-TuneManifest $root)) {
    foreach ($d in @($m.deps)) {
      if (-not $loaded.ContainsKey([string]$d)) {
        throw ("module '" + $m.name + "' depends on '" + $d + "' which is not loaded before it (check lib/modules.json order)")
      }
    }
    $p = Join-Path $root ('lib\' + $m.file)
    if (-not (Test-Path $p)) { throw ('manifest lists missing file: ' + $p) }
    $loaded[[string]$m.name] = $true
    $paths += $p
  }
  return $paths
}
