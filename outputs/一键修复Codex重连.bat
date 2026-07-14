@echo off
setlocal
chcp 65001 >nul

set "PS_SCRIPT="
for %%F in ("%~dp0*.ps1") do set "PS_SCRIPT=%%~fF"

if not defined PS_SCRIPT (
    echo ERROR: PowerShell repair script was not found in "%~dp0".
    exit /b 1
)

if /i "%~1"=="status" goto status
if /i "%~1"=="remove" goto remove
if not "%~1"=="" goto usage

echo Repairing Codex proxy settings...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Install -RestartCodex
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Remove -RestartCodex
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   %~nx0          Repair proxy settings and restart Codex
echo   %~nx0 status   Show current settings
echo   %~nx0 remove   Restore the saved settings and restart Codex
exit /b 2
