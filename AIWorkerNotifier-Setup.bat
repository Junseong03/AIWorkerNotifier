@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"
title AI Worker Notifier Setup

rem Short launcher only. Korean UI lives in scripts\manage-setup.ps1
rem Save this file as UTF-8 with BOM for cmd.exe compatibility.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0scripts\manage-setup.ps1"

set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%
