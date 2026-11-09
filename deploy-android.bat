@echo off
REM Builds and deploys beats-me to an Android phone. See deploy-android.ps1 for options
REM (-Attach, -Logs, -Force, -Pair, -Device <serial>).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-android.ps1" %*
exit /b %ERRORLEVEL%
