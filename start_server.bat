@echo off
REM ===========================================================================
REM  start_server.bat  -  start Qwen3.8-27B (Q4) llama-server (no download/deploy)
REM
REM  Prerequisite: qwen38_deploy.ps1 / deploy_and_run.bat already did the first-time
REM  download; llama.cpp\llama-server.exe, the model GGUF and MTP head exist here.
REM
REM  Usage:
REM    double-click this file           normal start (text-only, 32K context)
REM    start_server.bat -Vision         enable vision (swap model to *-VL GGUF first)
REM    extra args are accepted, e.g.:
REM    start_server.bat -Ctx 65536      raise context to 64K (only if VRAM allows)
REM    start_server.bat -Port 8081      change server port
REM    start_server.bat -ApiKeyFile f   use API key file f ("" disables auth; default api_keys.txt)
REM
REM  Debug: all tunables below are plain "set" lines; edit them, no need to touch
REM  the command assembly further down.
REM ===========================================================================

REM ---- tunables (edit here, nothing below needs changing) ----
set "MODEL_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf"
REM main model file
set "MODEL_ALIAS=qwen3.8-27B"
REM model display name (--alias); clients fill this short name
set "MTP_FILE=mtp-Qwen3.8-27B-Q4_0.gguf"
REM MTP speculative-decoding draft head
set "MMPROJ_FILE=mmproj-F16.gguf"
REM vision projector file (used only when Vision is enabled)
set "CTX_SIZE=98304"
REM context window -c; try 65536 / 98304 only if VRAM allows
set "REASONING=high"
REM reasoning_effort: low / medium / high / xhigh
set "PORT=8080"
REM server port
set "HOST=0.0.0.0"
REM listen address; use 127.0.0.1 for local-only
set "API_KEY="
REM single inline API key (--api-key). Leave empty; only for local testing.
REM Prefer API_KEY_FILE so the secret stays out of this script AND out of the
REM process command line (tasklist /v).
set "API_KEY_FILE=api_keys.txt"
REM API keys file, one per line (# = comment). Auth is ON when this file exists;
REM missing file falls back to no-auth with a warning. Create keys with
REM gen_api_key.bat. Override with -ApiKeyFile <path> (pass "" to disable).
set "PARALLEL=1"
REM concurrent slots (24GB VRAM only fits 1)
set "NGL=99"
REM GPU offload layers; 99 = fully offload (do not lower, falls back to CPU)
set "FLASH_ATTN=on"
REM Flash Attention: on / off
set "CACHE_K=q8_0"
REM KV cache quantization (K channel)
set "CACHE_V=q8_0"
REM KV cache quantization (V channel)
set "SPEC_TYPE=draft-mtp"
REM speculative decoding type; set empty to disable (--spec-* omitted automatically)

REM ---- parse optional args (override defaults above) ----
set "ENABLE_VISION=0"
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="-Vision" ( set "ENABLE_VISION=1" & shift & goto parse_args )
if /i "%~1"=="-Ctx"     ( set "CTX_SIZE=%~2"    & shift & shift & goto parse_args )
if /i "%~1"=="-Port"      ( set "PORT=%~2"         & shift & shift & goto parse_args )
if /i "%~1"=="-ApiKey"     ( set "API_KEY=%~2"      & shift & shift & goto parse_args )
if /i "%~1"=="-ApiKeyFile" ( set "API_KEY_FILE=%~2" & shift & shift & goto parse_args )
echo Unknown arg: %~1
shift
goto parse_args
:args_done

REM ---- locate llama-server.exe (recursive; flat and nested dirs both work) ----
set "SERVER_EXE="
for /r "llama.cpp" %%f in (llama-server.exe) do ( if exist "%%f" ( set "SERVER_EXE=%%f" & goto found_server ) )
echo [ERROR] llama-server.exe not found under llama.cpp. Run deploy_and_run.bat first.
pause
exit /b 1
:found_server

REM ---- model file self-check ----
if not exist "%MODEL_FILE%" (
    echo [ERROR] model file not found: %MODEL_FILE%
    pause
    exit /b 1
)
if not exist "%MTP_FILE%" (
    echo [ERROR] MTP draft head not found: %MTP_FILE%
    pause
    exit /b 1
)

REM ---- pass reasoning_effort via env var (avoids cmd quoting issues) ----
set "LLAMA_ARG_CHAT_TEMPLATE_KWARGS={"reasoning_effort":"%REASONING%"}"

REM ---- assemble launch args (all from the set vars above) ----
set "ARGS=-m %MODEL_FILE% --alias %MODEL_ALIAS% -c %CTX_SIZE% --parallel %PARALLEL% -ngl %NGL% -fa %FLASH_ATTN% --cache-type-k %CACHE_K% --cache-type-v %CACHE_V% --host %HOST% --port %PORT%"

REM ---- speculative decoding: append --spec-* only if SPEC_TYPE is set ----
if "%SPEC_TYPE%"=="" goto no_spec
set "ARGS=%ARGS% --spec-type %SPEC_TYPE% --spec-draft-model %MTP_FILE%"
:no_spec

REM ---- auth: --api-key-file wins over --api-key; warn if bound public with no key ----
if not defined API_KEY_FILE goto auth_check_key
if not exist "%API_KEY_FILE%" ( echo [WARN] %API_KEY_FILE% not found - starting WITHOUT auth. Run gen_api_key.bat to create keys. & goto auth_warn )
set "ARGS=%ARGS% --api-key-file %API_KEY_FILE%"
goto auth_done
:auth_check_key
if not defined API_KEY goto auth_warn
set "ARGS=%ARGS% --api-key %API_KEY%"
goto auth_done
:auth_warn
if "%HOST%"=="0.0.0.0" echo [WARN] HOST=0.0.0.0 with no api-key -- anyone on the LAN can call the model. Set API_KEY or API_KEY_FILE above.
:auth_done

REM ---- vision: append --mmproj only when ENABLE_VISION=1 ----
if "%ENABLE_VISION%"=="0" goto no_vision
if exist "%MMPROJ_FILE%" goto vision_ok
echo [ERROR] Vision enabled but projector not found: %MMPROJ_FILE% (use a *-VL model and its matching projector)
pause
exit /b 1
:vision_ok
set "ARGS=%ARGS% --mmproj %MMPROJ_FILE%"
echo [START] llama-server (vision ON)  http://%HOST%:%PORT%
goto launch
:no_vision
echo [START] llama-server  http://%HOST%:%PORT%
:launch

echo [exe  ] %SERVER_EXE%
echo [args ] %ARGS%
echo [hint ] Ctrl+C to stop
echo ===========================================================================

"%SERVER_EXE%" %ARGS%
