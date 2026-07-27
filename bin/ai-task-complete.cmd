@echo off
setlocal
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai-task-complete.internal.ps1" %*
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%
