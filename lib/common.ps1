# lib/common.ps1 - logging + process helpers.
# NAMING RULE (hard-won): never define functions shorter/named like builtin aliases (r, h, sls, ...).
# All public functions here are verb + Tune/Gguf/Nvidia prefix, 3+ chars, checked against Get-Alias.
# ASCII-only source.

$global:TuneReport = New-Object System.Collections.Generic.List[string]

function Write-TuneLog($m) {
  if (-not $global:TuneReport) { $global:TuneReport = New-Object System.Collections.Generic.List[string] }
  Write-Host $m
  $global:TuneReport.Add([string]$m)
}

function Save-TuneLog([string]$path) {
  $global:TuneReport | Set-Content -Path $path -Encoding UTF8
}

function Stop-TuneServer {
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
}
