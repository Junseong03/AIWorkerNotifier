@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"

rem Cursor user-level stop hook entry.
rem Always resolve scripts from this repository bin directory so PATH drift
rem does not break notifications.

set "HOOK_SCRIPT=%~dp0..\integrations\cursor\notify-agent-stop.ps1"
if not exist "%HOOK_SCRIPT%" (
  echo NOTIFY_RESULT=NOTIFY_CALLED_BUT_FAILED 1>&2
  echo {}
  exit /b 0
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HOOK_SCRIPT%" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo {}
  exit /b 0
)
exit /b 0
