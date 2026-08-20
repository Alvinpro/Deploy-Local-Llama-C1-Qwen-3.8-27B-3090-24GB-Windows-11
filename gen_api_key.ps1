# gen_api_key.ps1 - 生成 sk-* 开头的 API key，供 llama-server 鉴权（--api-key-file）使用
#
# 用法:
#   .\gen_api_key.ps1                 # 生成 1 个 key 并追加到 api_keys.txt
#   .\gen_api_key.ps1 -Count 3        # 一次生成 3 个
#   .\gen_api_key.ps1 -NoAppend       # 只打印，不写文件
#   .\gen_api_key.ps1 -OutFile x.txt  # 指定输出文件

param(
    [int]$Count = 1,
    [switch]$NoAppend,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

if ($OutFile -eq "") { $OutFile = Join-Path $PSScriptRoot "api_keys.txt" }

# 加密级随机 key: "sk-" + 32 随机字节（64 位 hex）
# 用 RandomNumberGenerator::Create().GetBytes()，兼容旧 .NET（Fill 需 4.6.2+）
function New-SkKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hex = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    return "sk-" + $hex
}

# 收集已有 key，避免重复
$existing = @{}
if (Test-Path $OutFile) {
    Get-Content $OutFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) { $existing[$line] = $true }
    }
}

$newKeys = @()
while ($newKeys.Count -lt $Count) {
    $key = New-SkKey
    if (-not $existing.ContainsKey($key)) {
        $existing[$key] = $true
        $newKeys += $key
    }
}

$newKeys | ForEach-Object { Write-Host $_ }

if ($NoAppend) {
    Write-Host "(未写文件 -NoAppend)"
} else {
    $newKeys | Add-Content -Path $OutFile -Encoding ASCII
    Write-Host "已追加 $($newKeys.Count) 个 key 到: $OutFile"
}
Write-Host "客户端请求头: Authorization: Bearer <key>"
