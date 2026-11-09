@echo off
setlocal
set "CODEX_RECOVERY_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "CODEX_RECOVERY_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%CODEX_RECOVERY_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-Codex.ps1" -Mode Diagnose
if errorlevel 1 pause
