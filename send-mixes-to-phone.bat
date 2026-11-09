@echo off
REM Sends every .beatsmix in D:\music to the connected Android phone (adb).
REM Extra options pass through: -Serial <id>, -Setup. Default folder: D:\music.
set "DIR=D:\music"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\analyze-this\tools\send-beatsmix.ps1" -Dir "%DIR%" %*
exit /b %ERRORLEVEL%
