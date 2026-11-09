@echo off
rem Starts (or restarts) beats_me on Windows.
set "FLUTTER=%~dp0..\flutter-sdk\bin\flutter.bat"
taskkill /F /IM beats_me.exe >nul 2>&1
cd /d "%~dp0"
call "%FLUTTER%" run -d windows
