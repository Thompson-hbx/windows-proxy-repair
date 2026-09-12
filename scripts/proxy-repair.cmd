@echo off
setlocal
chcp 65001 >nul

set "PS_SCRIPT=%~dp0proxy-repair.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: PowerShell repair script was not found:
    echo   "%PS_SCRIPT%"
    exit /b 1
)

if /i "%~1"=="status" goto status
if /i "%~1"=="diagnose" goto diagnose
if /i "%~1"=="test" goto test
if /i "%~1"=="remove" goto remove
if not "%~1"=="" goto usage

echo This tool repairs the Windows user proxy environment for env-aware clients.
echo It is intended for Codex, Antigravity language_server, Go/CLI tools, and similar processes.
echo.
echo WARNING: Running VS Code, Codex, and Antigravity may be restarted so they inherit the new environment.
echo Save all open files before continuing.
choice /c YN /n /m "Continue? [Y/N] "
if errorlevel 2 exit /b 3

echo.
echo Detecting and repairing proxy environment...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Install -Profile All -RestartRunningApps
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo.
    echo Repair failed. Review the error above.
) else (
    echo.
    echo Repair completed. Affected running applications will be restarted when detectable.
)
echo.
pause
exit /b %EXIT_CODE%

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Status -Profile All
exit /b %ERRORLEVEL%

:diagnose
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Diagnose -Profile All
exit /b %ERRORLEVEL%

:test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Test -Profile All
exit /b %ERRORLEVEL%

:remove
echo WARNING: Rollback restores the saved user proxy environment.
echo Running VS Code, Codex, and Antigravity may be restarted afterward.
echo Save all open files before continuing.
choice /c YN /n /m "Continue? [Y/N] "
if errorlevel 2 exit /b 3

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Remove -Profile All -RestartRunningApps
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%

:usage
echo Usage:
echo   %~nx0            Repair proxy environment and restart detected clients
echo   %~nx0 diagnose   Compare direct and proxied routes without changing settings
echo   %~nx0 status     Show proxy layers and saved rollback state
echo   %~nx0 test       Test required OpenAI and Google endpoints through the proxy
echo   %~nx0 remove     Restore the saved user environment
exit /b 2
