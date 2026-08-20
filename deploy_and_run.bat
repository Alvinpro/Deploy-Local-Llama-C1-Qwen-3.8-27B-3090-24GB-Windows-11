@echo off
REM One-click launcher for Qwen3.8-27B on RTX 3090 (Windows).
REM Double-click this file. First run downloads ~17.6 GB model + mmproj + binaries (slow); later runs skip downloads.
REM Vision is ON by default (Qwen3.8-27B is a native VL model; mmproj stays on CPU). Use "deploy_and_run.bat -NoVision" for text-only.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0deploy_and_run.ps1" %*
pause
