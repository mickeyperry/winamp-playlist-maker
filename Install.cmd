@echo off
REM Double-click me to install the Winamp Playlist Maker right-click menu.
REM Per-user install, no admin rights needed.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
pause
