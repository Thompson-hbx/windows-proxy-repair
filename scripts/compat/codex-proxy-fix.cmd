@echo off
setlocal
chcp 65001 >nul

set "PS_SCRIPT=%~dp0codex-proxy-fix.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: PowerShell compatibility script was not found:
    echo   "%PS_SCRIPT%"
    exit /b 1
)

if /i "%~1"=="status" goto status
if /i "%~1"=="remove" goto remove
if not "%~1"=="" goto usage

echo WARNING: This repair will close and restart VS Code and Codex.
echo Save all open files before continuing.
choice /c YN /n /m "Continue? [Y/N] "
if errorlevel 2 exit /b 3

echo.
echo Repairing Codex proxy settings...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Install -RestartCodex -RestartVSCode
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo.
    echo Repair failed. Keep this window open and review the error above.
) else (
    echo.
    echo Repair completed. Codex restart has been scheduled.
)
echo.
pause
exit /b %EXIT_CODE%

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Status
exit /b %ERRORLEVEL%

:remove
echo WARNING: Rollback will close and restart VS Code and Codex.
echo Save all open files before continuing.
choice /c YN /n /m "Continue? [Y/N] "
if errorlevel 2 exit /b 3

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Remove -RestartCodex -RestartVSCode
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   %~nx0          Repair proxy settings and restart VS Code and Codex
echo   %~nx0 status   Show current settings
echo   %~nx0 remove   Restore saved settings and restart VS Code and Codex
exit /b 2
