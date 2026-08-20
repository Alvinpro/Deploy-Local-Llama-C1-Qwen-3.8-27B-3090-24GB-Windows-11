@echo off
REM One-click launcher for Qwen3.8-27B on RTX 3090 (Windows).
REM Double-click this file. First run downloads ~17.6 GB model + binaries (slow); later runs skip downloads.
REM Vision: use "deploy_and_run.bat -Vision" (or set $ENABLE_VISION=$true in the ps1); requires a *-VL GGUF as $MODEL_FILE plus the matching projector file. A text-only model cannot see images even if enabled.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0qwen38_deploy.ps1" %*
pause
