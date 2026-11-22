# lib/launcher.ps1 - generate start/stop .cmd bodies (+ desktop shortcuts). ASCII-only source.
# String traps encoded as regression tests in tests/smoke.ps1:
#   1) never use -f formatting on strings containing literal { }
#   2) never embed $$ inside double-quoted strings (expands to empty)

function New-TuneLauncherBodies($plan, [string]$argLine, [string]$llamaExe) {
  $health = 'try{$h=Invoke-RestMethod http://127.0.0.1:' + $plan.Port + '/health -TimeoutSec 2; if($h.status -eq ''ok''){exit 10}}catch{}; exit 0'
  $waith  = 'try{$h=Invoke-RestMethod http://127.0.0.1:' + $plan.Port + '/health -TimeoutSec 3; if($h.status -eq ''ok''){exit 0}}catch{}; exit 1'
  $startBody = @"
@echo off
title Start LLM
powershell -NoProfile -Command "$health"
if %errorlevel%==10 goto open
echo Starting llama-server (auto-tuned for this machine). Loading model, please wait...
start "llama-server" /min "$llamaExe" $argLine
:waitloop
ping -n 4 127.0.0.1 >nul
tasklist /fi "imagename eq llama-server.exe" | find /i "llama-server.exe" >nul
if errorlevel 1 (echo ERROR: llama-server exited during loading - re-run this file in a console window to see the error. & exit /b 1)
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
ping -n 3 127.0.0.1 >nul
"@
  return @{ Start = $startBody; Stop = $stopBody }
}

function Write-TuneLaunchers([string]$startPath, [string]$stopPath, $bodies, $plan, [bool]$noShortcut, [string]$workDir) {
  Set-Content -Path $startPath -Value $bodies.Start -Encoding ASCII
  Set-Content -Path $stopPath  -Value $bodies.Stop  -Encoding ASCII
  Write-TuneLog "Wrote $startPath"
  Write-TuneLog "Wrote $stopPath"
  if ($noShortcut) { return }
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  # CN labels via unicode escapes (source must stay ASCII): start / stop
  $lnkStart = Join-Path $desktop (([regex]::Unescape('\u542f\u52a8')) + 'LLM.lnk')
  $lnkStop  = Join-Path $desktop (([regex]::Unescape('\u505c\u6b62'))  + 'LLM.lnk')
  $sc = $ws.CreateShortcut($lnkStart)
  $sc.TargetPath = $startPath; $sc.WorkingDirectory = $workDir
  $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
  $sc.Description = 'Start auto-tuned llama-server'; $sc.Save()
  $sc2 = $ws.CreateShortcut($lnkStop)
  $sc2.TargetPath = $stopPath; $sc2.WorkingDirectory = $workDir
  $sc2.IconLocation = "$env:SystemRoot\System32\shell32.dll,132"
  $sc2.Description = 'Stop llama-server'; $sc2.Save()
  Write-TuneLog "Desktop shortcuts created: $lnkStart ; $lnkStop"
}
