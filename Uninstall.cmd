@echo off
REM Double-click me to remove the right-click menu.
REM Leaves these files on disk.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\uninstall-context-menu.ps1"

echo.
pause
