@echo off
REM gen_api_key.bat - double-click launcher for gen_api_key.ps1
REM generates sk-* API keys into api_keys.txt (llama-server --api-key-file)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gen_api_key.ps1" %*
echo.
pause
