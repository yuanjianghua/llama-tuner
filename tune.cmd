@echo off
title LLM Auto Tuner
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tune.ps1" %*
pause
