@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai-task-complete.internal.ps1" %*
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%