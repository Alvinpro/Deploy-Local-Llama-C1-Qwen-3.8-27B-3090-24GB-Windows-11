# qwen38_deploy.ps1
# One-click deploy Qwen3.8-27B (Q4) on a single RTX 3090 / 24GB GPU, Windows.
# Downloads the latest llama.cpp CUDA build + GGUF model + MTP draft head, then launches llama-server.
# Optional vision/multimodal support via -Vision (see $ENABLE_VISION below).
# Re-running is safe: already-downloaded files are skipped.

param([switch]$Vision)

$ErrorActionPreference = "Stop"
$WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $WorkDir

# ---- tunables (edit if needed) ----
$MODEL_REPO = "unsloth/Qwen3.8-27B-GGUF"
$MODEL_FILE = "Qwen3.8-27B-UD-Q4_K_XL.gguf"   # ~17.6 GB, fits 24 GB VRAM with room for KV cache
$MODEL_ALIAS = "qwen3.8-27b"                     # short name shown in /v1/models; clients fill this
$MTP_REPO   = "ggml-org/Qwen3.8-27B-GGUF"
$MTP_FILE   = "mtp-Qwen3.8-27B-Q4_0.gguf"       # built-in MTP head for speculative decoding
$CTX_SIZE   = 98304                              # 96K safe sweet spot on 24GB; raise to 65536/98304 only if VRAM allows
$REASONING  = "high"                             # low | medium | high | xhigh ; default xhigh overthinks
$PORT       = 8080

# API key authentication (llama-server --api-key / --api-key-file).
# Auth is ON by default via api_keys.txt (one random token per line, # comment).
# $API_KEY_FILE wins over $API_KEY; missing file falls back to no-auth + warning.
# Keep keys out of this script AND out of the process command line.
$API_KEY      = ""             # single inline key; only for local testing
$API_KEY_FILE = "api_keys.txt" # default keys file (create with gen_api_key.bat)

# Network proxy for GFW-restricted CDNs (GitHub / HuggingFace). Set to "" to disable.
$PROXY = "http://127.0.0.1:10808"
if ($PROXY) {
    $env:HTTP_PROXY  = $PROXY
    $env:HTTPS_PROXY = $PROXY
    $env:http_proxy  = $PROXY
    $env:https_proxy = $PROXY
}

# Vision / multimodal support:
#   - enable by setting $ENABLE_VISION = $true below, OR run:  qwen38_deploy.ps1 -Vision
#   - REQUIRES a vision model: point $MODEL_FILE at a *-VL GGUF and set $MMPROJ_REPO / $MMPROJ_FILE
#     to that repo's multimodal projector. The plain Qwen3.8-27B text model will NOT see images.
$ENABLE_VISION = $false
if ($Vision.IsPresent) { $ENABLE_VISION = $true }
$MMPROJ_REPO   = "unsloth/Qwen3.8-27B-GGUF"
$MMPROJ_FILE   = "mmproj-F16.gguf"

# 1) llama.cpp latest CUDA build (needs build >= b10451 for qwen3.8-hybrid; latest is fine)
#    Robust: finds the exe recursively (flat OR nested zip layout), verifies the download is a
#    real zip (not an HTML error page), and only fails with a clear message if the binary is
#    truly missing -- instead of crashing on a hardcoded path.
$buildDir  = "llama.cpp"
$serverExe = "llama-server.exe"

function Find-LlamaServer {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    return (Get-ChildItem -Path $Dir -Recurse -Filter $serverExe -ErrorAction SilentlyContinue |
            Select-Object -First 1).FullName
}

# Unwrap single-folder wrappers (e.g. llama-b12345/) and copy all contents into $Dest.
function Copy-BuildTree {
    param([string]$Source, [string]$Dest)
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
    $src = $Source
    while ($true) {
        $entries = Get-ChildItem -Path $src -Force
        if (($entries.Count -eq 1) -and ($entries[0].PSIsContainer)) { $src = $entries[0].FullName }
        else { break }
    }
    Copy-Item -Path (Join-Path $src '*') -Destination $Dest -Recurse -Force
}

# Best-effort recursive delete. Some sandboxes wrap Remove-Item in a "safe delete" that
# fails closed when the Recycle Bin is unavailable; cleanup must never abort the deploy.
function Remove-PathSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try { Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop } catch { }
}

$serverPath = Find-LlamaServer $buildDir
if (-not $serverPath) {
    Write-Host "[1/5] Fetching latest llama.cpp CUDA build..."
    try {
        $apiParams = @{}
        if ($PROXY) { $apiParams['Proxy'] = $PROXY; $apiParams['ProxyUseDefaultCredentials'] = $true }
        $api = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" @apiParams
    } catch {
        throw "Cannot reach GitHub API (api.github.com). If you are behind GFW, set a proxy, or download 'llama-*-bin-win-cuda-12.4-x64.zip' + 'cudart-llama-*-bin-win-cuda-12.4-x64.zip' manually and extract into '$buildDir'."
    }
    $tag = $api.tag_name

    # The Windows CUDA release ships TWO zips we need:
    #   - the binaries build (llama-*-bin-win-cuda-12.4-x64.zip)  -> llama-server.exe + ggml-*.dll
    #   - the cudart bundle   (cudart-llama-*-bin-win-cuda-12.4-x64.zip) -> CUDA runtime DLLs
    # The cudart-only zip has NO exe, so we must never pick it as the binaries build.
    function Select-Asset {
        param($Assets, $Primary, $Fallback)
        $a = $Assets | Where-Object { $_.name -match $Primary } | Select-Object -First 1
        if (-not $a) { $a = $Assets | Where-Object { $_.name -match $Fallback } | Select-Object -First 1 }
        return $a
    }
    $binAsset = Select-Asset $api.assets '^llama-.*bin-win-cuda-12\.4-x64\.zip$' '^llama-.*bin-win-cuda.*x64\.zip$'
    $cudAsset = Select-Asset $api.assets '^cudart-llama-.*bin-win-cuda-12\.4-x64\.zip$' '^cudart-.*bin-win-cuda.*x64\.zip$'
    if (-not $binAsset) { throw "No Windows CUDA binaries asset found in release $tag" }
    Write-Host "  -> $tag"
    Write-Host "     binaries : $($binAsset.name)"
    if ($cudAsset) { Write-Host "     cudart   : $($cudAsset.name)" }

    # Download + extract one asset (resumable) into the shared temp tree.
    function Fetch-Zip {
        param($Asset, $Label)
        $zipPath = Join-Path $WorkDir ($Asset.name)
        Write-Host "  Downloading $Label ($($Asset.name), resumable)..."
        & curl.exe -L -C - --retry 3 --retry-delay 5 $Asset.browser_download_url -o $zipPath
        if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1MB) {
            throw "Download failed or too small (<1MB): $zipPath"
        }
        return $zipPath
    }

    $tmp = Join-Path $WorkDir "llama.cpp.tmp"
    Remove-PathSafe $tmp
    try {
        # binaries first; verify it actually contains the server exe
        $binZip = Fetch-Zip $binAsset "binaries"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($binZip)
        $exeEntry = $zip.Entries | Where-Object { $_.Name -eq $serverExe } | Select-Object -First 1
        if (-not $exeEntry) {
            $names = ($zip.Entries | Select-Object -ExpandProperty Name) -join ', '
            $zip.Dispose()
            throw "Binaries archive has no $serverExe (wrong asset?). Contents: $names"
        }
        $zip.Dispose()
        Expand-Archive -Path $binZip -DestinationPath $tmp -Force
        Remove-PathSafe $binZip

        # cudart bundle (runtime DLLs) if present -- merge on top so llama-server can load CUDA
        if ($cudAsset) {
            $cudZip = Fetch-Zip $cudAsset "cudart"
            Expand-Archive -Path $cudZip -DestinationPath $tmp -Force
            Remove-PathSafe $cudZip
        }

        Copy-BuildTree -Source $tmp -Dest $buildDir
    } finally {
        Remove-PathSafe $tmp
    }

    $serverPath = Find-LlamaServer $buildDir
    if (-not $serverPath) { throw "Still cannot find $serverExe after extraction." }
    Write-Host "  -> llama.cpp ready at: $serverPath"
}

# 2) Model GGUF (~17.6 GB, resumable)
if (-not (Test-Path $MODEL_FILE)) {
    Write-Host "[2/5] Downloading model GGUF (~17.6 GB, resumable)..."
    $url = "https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE"
    & curl.exe -L -C - $url -o $MODEL_FILE
}

# 3) MTP draft head
if (-not (Test-Path $MTP_FILE)) {
    Write-Host "[3/5] Downloading MTP draft head..."
    $url = "https://huggingface.co/$MTP_REPO/resolve/main/$MTP_FILE"
    & curl.exe -L -C - $url -o $MTP_FILE
}

# 4) Vision projector (optional, only when $ENABLE_VISION)
if ($ENABLE_VISION) {
    if (-not (Test-Path $MMPROJ_FILE) -or (Get-Item $MMPROJ_FILE).Length -lt 1MB) {
        Write-Host "[4/5] Downloading vision projector ($MMPROJ_FILE, resumable)..."
        $url = "https://huggingface.co/$MMPROJ_REPO/resolve/main/$MMPROJ_FILE"
        & curl.exe -L -C - $url -o $MMPROJ_FILE
    }
    if (-not (Test-Path $MMPROJ_FILE) -or (Get-Item $MMPROJ_FILE).Length -lt 1MB) {
        throw "Vision projector missing/too small: $MMPROJ_FILE. Vision needs a Qwen3.8-VL model -- set `$MODEL_FILE to a *-VL GGUF and `$MMPROJ_REPO/`$MMPROJ_FILE to that repo's projector."
    }
}

# 5) Launch
# Pass reasoning_effort via the env var (LLAMA_ARG_CHAT_TEMPLATE_KWARGS) instead of the
# --chat-template-kwargs CLI arg: PowerShell strips the JSON's double quotes when quoting
# native-command arguments, which makes llama-server fail to parse it. The env var is read
# verbatim, so the JSON survives intact.
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"reasoning_effort":"' + $REASONING + '"}'
$serverArgs = @(
    '-m', $MODEL_FILE,
    '--alias', $MODEL_ALIAS,
    '-c', $CTX_SIZE, '--parallel', '1',
    '-ngl', '99', '-fa', 'on',
    '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
    '--spec-type', 'draft-mtp',
    '--spec-draft-model', $MTP_FILE,
    '--host', '0.0.0.0', '--port', $PORT
)
if ($ENABLE_VISION) {
    if (-not (Test-Path $MMPROJ_FILE)) { throw "Vision enabled but projector missing: $MMPROJ_FILE" }
    $serverArgs += @('--mmproj', $MMPROJ_FILE)
    Write-Host "[5/5] Starting llama-server (vision ON) at http://127.0.0.1:$PORT  (Ctrl+C to stop)"
} else {
    Write-Host "[5/5] Starting llama-server at http://127.0.0.1:$PORT  (Ctrl+C to stop)"
}

# API key auth: file wins over inline key
if ($API_KEY_FILE) {
    if (-not (Test-Path $API_KEY_FILE)) {
        Write-Host "[WARN] $API_KEY_FILE not found - starting WITHOUT auth. Run gen_api_key.bat to create keys."
    } else {
        $serverArgs += @('--api-key-file', $API_KEY_FILE)
    }
} elseif ($API_KEY) {
    $serverArgs += @('--api-key', $API_KEY)
} else {
    Write-Host "[WARN] Server bound to 0.0.0.0 with no api-key -- anyone on the LAN can call the model. Set `$API_KEY or `$API_KEY_FILE above."
}

& $serverPath @serverArgs
