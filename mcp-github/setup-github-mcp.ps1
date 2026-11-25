#Requires -Version 5.1
<#
.SYNOPSIS
    下载锁定版本的官方 github-mcp-server 二进制到 mcp-github/bin/（不入库）。

.DESCRIPTION
    - 版本锁定：$script:McpGithubBinaryVersion（当前 v2.1.0，与服务接入说明的验证结论一致）。
    - 下载 GitHub Releases 的 Windows x86_64 zip，解压 github-mcp-server.exe 到 mcp-github/bin/。
    - 下载前校验 checksums 文件中该资产的 SHA-256，不匹配即中止。
    - 二进制目录 mcp-github/bin/ 已被 .gitignore 排除，不会入库。

.PARAMETER Force
    已存在二进制时强制重新下载覆盖。

.EXAMPLE
    pwsh -File mcp-github\setup-github-mcp.ps1
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$script:McpGithubBinaryVersion = 'v2.1.0'
$script:McpGithubAssetName = 'github-mcp-server_Windows_x86_64.zip'
$script:McpGithubExeName = 'github-mcp-server.exe'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir = Join-Path $here 'bin'
$exePath = Join-Path $binDir $script:McpGithubExeName

if ((Test-Path -LiteralPath $exePath) -and -not $Force) {
    Write-Host "[setup] 二进制已存在：$exePath（如需重新下载请加 -Force）"
    exit 0
}

$base = "https://github.com/github/github-mcp-server/releases/download/$script:McpGithubBinaryVersion"
$zipUrl = "$base/$($script:McpGithubAssetName)"
$shaUrl = "$base/github-mcp-server_$($script:McpGithubBinaryVersion.TrimStart('v'))_checksums.txt"
$tmpZip = Join-Path $env:TEMP ("github-mcp-server_{0}.zip" -f [guid]::NewGuid().ToString('N'))
$tmpSha = Join-Path $env:TEMP ("github-mcp-server_checksums_{0}.txt" -f [guid]::NewGuid().ToString('N'))

try {
    Write-Host "[setup] 正在下载 $zipUrl …"
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -TimeoutSec 300
    Write-Host '[setup] 正在下载校验文件 …'
    Invoke-WebRequest -Uri $shaUrl -OutFile $tmpSha -UseBasicParsing -TimeoutSec 120

    $expected = $null
    foreach ($line in Get-Content -LiteralPath $tmpSha) {
        if ($line -match ('^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($script:McpGithubAssetName) + '\s*$')) {
            $expected = $Matches[1].ToLowerInvariant(); break
        }
    }
    if (-not $expected) { throw '校验文件中未找到该资产的 SHA-256，中止安装' }
    $actual = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw ("SHA-256 校验失败：期望 {0}，实际 {1}" -f $expected, $actual) }
    Write-Host '[setup] SHA-256 校验通过'

    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $binDir -Force

    if (-not (Test-Path -LiteralPath $exePath)) { throw '解压后未找到 github-mcp-server.exe，中止' }

    $verRes = & $exePath --version 2>&1
    Write-Host ("[setup] 安装完成：{0}（版本输出：{1}）" -f $exePath, ($verRes -join ' ').Trim())
    Write-Host '[setup] 下一步：运行 scripts/mcpctl.ps1（菜单 4 配置向导），在 mcp.config.json 的 services.github 段填写地址与个人访问令牌（不入库）'
    exit 0
}
catch {
    Write-Host ("[setup] 失败：{0}" -f $_.Exception.Message)
    Write-Host '[setup] 下一步：检查网络后重跑本脚本；或按 docs/services/服务接入说明.md 手动下载放置'
    exit 1
}
finally {
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpSha -Force -ErrorAction SilentlyContinue
}
