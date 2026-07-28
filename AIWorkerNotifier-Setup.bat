@echo off
setlocal EnableExtensions
title AI Worker Notifier Setup

rem ============================================================================
rem AI Worker Notifier setup menu
rem Place this file in the AIWorkerNotifier project root.
rem ============================================================================

set "APP_ROOT=%~dp0"
if "%APP_ROOT:~-1%"=="\" set "APP_ROOT=%APP_ROOT:~0,-1%"

set "BIN_DIR=%APP_ROOT%\bin"
set "SCRIPTS_DIR=%APP_ROOT%\scripts"

set "CLI_CMD=%BIN_DIR%\ai-task-complete.cmd"
set "NOTIFIER_CMD=%BIN_DIR%\AIWorkerNotifier.cmd"

set "INSTALL_PATH_SCRIPT=%SCRIPTS_DIR%\install-user-path.ps1"
set "REMOVE_PATH_SCRIPT=%SCRIPTS_DIR%\remove-user-path.ps1"
set "UNINSTALL_PATH_SCRIPT=%SCRIPTS_DIR%\uninstall-user-path.ps1"
set "WEBHOOK_SCRIPT=%SCRIPTS_DIR%\set-discord-webhook.ps1"

set "RUNTIME_ROOT=%LOCALAPPDATA%\AIWorkerNotifier"
set "WEBHOOK_FILE=%RUNTIME_ROOT%\state\discord-webhook.dpapi"

goto :MENU


:MENU
call :REFRESH_STATUS

cls
echo ============================================================
echo                  AI Worker Notifier Setup
echo ============================================================
echo.
echo Application : %APP_ROOT%
echo User PATH   : %PATH_STATUS%
echo Webhook     : %WEBHOOK_STATUS%
echo Watcher     : %WATCHER_STATUS%
echo.
echo   1. Register commands in the current user PATH
echo   2. Remove commands from the current user PATH
echo   3. Configure or replace the Discord Webhook
echo   4. Remove the locally stored Discord Webhook
echo   5. Show detailed setup status
echo   6. Send a test notification
echo   7. Start AI Worker Notifier
echo   8. Exit
echo.
echo Notes:
echo   - PATH changes apply to newly opened terminal sessions.
echo   - Removing PATH does not delete program files or runtime data.
echo   - Test notification delivery requires the watcher to be running.
echo.

choice /C 12345678 /N /M "Select an option [1-8]: "

if errorlevel 8 goto :EXIT_OK
if errorlevel 7 goto :START_NOTIFIER
if errorlevel 6 goto :SEND_TEST
if errorlevel 5 goto :SHOW_STATUS
if errorlevel 4 goto :REMOVE_WEBHOOK
if errorlevel 3 goto :SET_WEBHOOK
if errorlevel 2 goto :REMOVE_PATH
if errorlevel 1 goto :ADD_PATH

goto :MENU


:ADD_PATH
cls
echo ============================================================
echo                    Register User PATH
echo ============================================================
echo.

if not exist "%BIN_DIR%\" (
    echo [ERROR] Command directory was not found:
    echo   %BIN_DIR%
    echo.
    pause
    goto :MENU
)

if not exist "%CLI_CMD%" (
    echo [ERROR] Required command was not found:
    echo   %CLI_CMD%
    echo.
    pause
    goto :MENU
)

if not exist "%NOTIFIER_CMD%" (
    echo [ERROR] Required command was not found:
    echo   %NOTIFIER_CMD%
    echo.
    pause
    goto :MENU
)

if exist "%INSTALL_PATH_SCRIPT%" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
        -File "%INSTALL_PATH_SCRIPT%"

    set "RESULT=%ERRORLEVEL%"
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
        -Command "$ErrorActionPreference='Stop'; $target=[IO.Path]::GetFullPath('%BIN_DIR%').TrimEnd('\'); $current=[Environment]::GetEnvironmentVariable('Path','User'); $items=@($current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $found=$false; foreach($item in $items){ try { if([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($item)).TrimEnd('\') -ieq $target){ $found=$true } } catch {} }; if($found){ Write-Host '[INFO] The command directory is already registered.'; exit 0 }; [Environment]::SetEnvironmentVariable('Path',(($items + $target) -join ';'),'User'); Write-Host '[OK] Registered the command directory in the current user PATH.'"

    set "RESULT=%ERRORLEVEL%"
)

echo.
if not "%RESULT%"=="0" (
    echo [ERROR] PATH registration failed with code %RESULT%.
) else (
    echo Open a new PowerShell or Cursor CLI session before testing.
)

echo.
pause
goto :MENU


:REMOVE_PATH
cls
echo ============================================================
echo                     Remove User PATH
echo ============================================================
echo.
echo The following directory will be removed from the current
echo user PATH:
echo.
echo   %BIN_DIR%
echo.
echo Program files and runtime data will not be deleted.
echo.

choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 2 goto :MENU

if exist "%REMOVE_PATH_SCRIPT%" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
        -File "%REMOVE_PATH_SCRIPT%"

    set "RESULT=%ERRORLEVEL%"
) else if exist "%UNINSTALL_PATH_SCRIPT%" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
        -File "%UNINSTALL_PATH_SCRIPT%"

    set "RESULT=%ERRORLEVEL%"
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
        -Command "$ErrorActionPreference='Stop'; $target=[IO.Path]::GetFullPath('%BIN_DIR%').TrimEnd('\'); $current=[Environment]::GetEnvironmentVariable('Path','User'); $items=@($current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $kept=@(); $removed=0; foreach($item in $items){ $match=$false; try { if([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($item)).TrimEnd('\') -ieq $target){ $match=$true } } catch {}; if($match){ $removed++ } else { $kept += $item } }; if($removed -eq 0){ Write-Host '[INFO] The command directory is not registered.'; exit 0 }; [Environment]::SetEnvironmentVariable('Path',($kept -join ';'),'User'); Write-Host '[OK] Removed the command directory from the current user PATH.'"

    set "RESULT=%ERRORLEVEL%"
)

echo.
if not "%RESULT%"=="0" (
    echo [ERROR] PATH removal failed with code %RESULT%.
) else (
    echo Open a new PowerShell or Cursor CLI session to apply the change.
)

echo.
pause
goto :MENU


:SET_WEBHOOK
cls
echo ============================================================
echo                  Configure Discord Webhook
echo ============================================================
echo.
echo The Webhook URL will not be displayed while typing.
echo It will be encrypted for the current Windows user.
echo.

if not exist "%WEBHOOK_SCRIPT%" (
    echo [ERROR] Webhook setup script was not found:
    echo   %WEBHOOK_SCRIPT%
    echo.
    pause
    goto :MENU
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%WEBHOOK_SCRIPT%"

set "RESULT=%ERRORLEVEL%"

echo.
if not "%RESULT%"=="0" (
    echo [ERROR] Webhook setup failed with code %RESULT%.
) else (
    echo Webhook configuration completed.
)

echo.
pause
goto :MENU


:REMOVE_WEBHOOK
cls
echo ============================================================
echo                 Remove Stored Discord Webhook
echo ============================================================
echo.
echo This removes only the locally encrypted credential:
echo.
echo   %WEBHOOK_FILE%
echo.
echo It does not delete the Webhook from Discord.
echo.

if not exist "%WEBHOOK_FILE%" (
    echo [INFO] No locally stored Webhook was found.
    echo.
    pause
    goto :MENU
)

choice /C YN /N /M "Remove the locally stored Webhook? [Y/N]: "
if errorlevel 2 goto :MENU

del /F /Q "%WEBHOOK_FILE%" >nul 2>&1

if exist "%WEBHOOK_FILE%" (
    echo.
    echo [ERROR] Failed to remove the locally stored Webhook.
) else (
    echo.
    echo [OK] Removed the locally stored Webhook credential.
)

echo.
pause
goto :MENU


:SHOW_STATUS
cls
echo ============================================================
echo                       Setup Status
echo ============================================================
echo.
echo Application root : %APP_ROOT%
echo Command directory: %BIN_DIR%
echo User PATH        : %PATH_STATUS%
echo Webhook          : %WEBHOOK_STATUS%
echo Watcher          : %WATCHER_STATUS%
echo Runtime root     : %RUNTIME_ROOT%
echo.
echo Files:
echo.

if exist "%CLI_CMD%" (
    echo   [FOUND]   %CLI_CMD%
) else (
    echo   [MISSING] %CLI_CMD%
)

if exist "%NOTIFIER_CMD%" (
    echo   [FOUND]   %NOTIFIER_CMD%
) else (
    echo   [MISSING] %NOTIFIER_CMD%
)

if exist "%WEBHOOK_FILE%" (
    echo   [FOUND]   %WEBHOOK_FILE%
) else (
    echo   [MISSING] %WEBHOOK_FILE%
)

echo.
echo Commands visible in this terminal:
echo.

where ai-task-complete >nul 2>&1
if errorlevel 1 (
    echo   ai-task-complete : NOT FOUND
) else (
    where ai-task-complete
)

where AIWorkerNotifier >nul 2>&1
if errorlevel 1 (
    echo   AIWorkerNotifier : NOT FOUND
) else (
    where AIWorkerNotifier
)

echo.
pause
goto :MENU


:SEND_TEST
cls
echo ============================================================
echo                   Send Test Notification
echo ============================================================
echo.

if not exist "%CLI_CMD%" (
    echo [ERROR] Notification command was not found:
    echo   %CLI_CMD%
    echo.
    pause
    goto :MENU
)

if not exist "%WEBHOOK_FILE%" (
    echo [ERROR] Discord Webhook is not configured.
    echo.
    echo Use menu option 3 first.
    echo.
    pause
    goto :MENU
)

call :REFRESH_WATCHER_STATUS

if /I not "%WATCHER_STATUS%"=="RUNNING" (
    echo [WARNING] AI Worker Notifier does not appear to be running.
    echo.
    echo The test event can still be created, but Discord delivery
    echo requires the watcher.
    echo.

    choice /C YN /N /M "Create the test event anyway? [Y/N]: "
    if errorlevel 2 goto :MENU
)

echo Creating test completion event...
echo.

call "%CLI_CMD%" ^
    --task "NOTIFIER-TEST" ^
    --status "AUDIT_COMPLETE" ^
    --summary "AI Worker Notifier setup test" ^
    --next "VERIFY_DISCORD_NOTIFICATION" ^
    --project "AIWorkerNotifier" ^
    --source "setup-menu" ^
    --scope "task"

set "RESULT=%ERRORLEVEL%"

echo.
if not "%RESULT%"=="0" (
    echo [ERROR] Test event creation failed with code %RESULT%.
) else (
    echo [OK] Test event created.
    echo.
    echo Check the watcher window, Discord channel, and mobile device.
)

echo.
pause
goto :MENU


:START_NOTIFIER
cls
echo ============================================================
echo                  Start AI Worker Notifier
echo ============================================================
echo.

if not exist "%NOTIFIER_CMD%" (
    echo [ERROR] Notifier command was not found:
    echo   %NOTIFIER_CMD%
    echo.
    pause
    goto :MENU
)

call :REFRESH_WATCHER_STATUS

if /I "%WATCHER_STATUS%"=="RUNNING" (
    echo [INFO] AI Worker Notifier already appears to be running.
    echo.
    pause
    goto :MENU
)

echo Starting AI Worker Notifier in a new command window...
echo.

start "AI Worker Notifier" cmd.exe /K call "%NOTIFIER_CMD%"

timeout /T 2 /NOBREAK >nul

call :REFRESH_WATCHER_STATUS

if /I "%WATCHER_STATUS%"=="RUNNING" (
    echo [OK] AI Worker Notifier is running.
) else (
    echo [INFO] The Notifier window was opened.
    echo Verify its startup log manually.
)

echo.
pause
goto :MENU


:REFRESH_STATUS
call :REFRESH_PATH_STATUS
call :REFRESH_WEBHOOK_STATUS
call :REFRESH_WATCHER_STATUS
exit /b 0


:REFRESH_PATH_STATUS
set "PATH_STATUS=NOT REGISTERED"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -Command "$target=[IO.Path]::GetFullPath('%BIN_DIR%').TrimEnd('\'); $current=[Environment]::GetEnvironmentVariable('Path','User'); foreach($item in @($current -split ';')){ try { if([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($item.Trim())).TrimEnd('\') -ieq $target){ exit 0 } } catch {} }; exit 1" >nul 2>&1

if "%ERRORLEVEL%"=="0" set "PATH_STATUS=REGISTERED"
exit /b 0


:REFRESH_WEBHOOK_STATUS
set "WEBHOOK_STATUS=NOT CONFIGURED"
if exist "%WEBHOOK_FILE%" set "WEBHOOK_STATUS=CONFIGURED"
exit /b 0


:REFRESH_WATCHER_STATUS
set "WATCHER_STATUS=NOT RUNNING"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -Command "$found=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match 'AIWorkerNotifier\.internal\.ps1' }; if($found){ exit 0 }; exit 1" >nul 2>&1

if "%ERRORLEVEL%"=="0" set "WATCHER_STATUS=RUNNING"
exit /b 0


:EXIT_OK
cls
echo AI Worker Notifier setup closed.
echo.
endlocal
exit /b 0