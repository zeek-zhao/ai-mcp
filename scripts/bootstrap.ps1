#Requires -Version 5.1
<#
.SYNOPSIS
    依赖初始化 Bootstrap（M4）。

.DESCRIPTION
    遍历服务注册表，按技术栈在各自子目录创建仓库内隔离环境：
      - python：创建 venv\ 虚拟环境；若存在 requirements.txt 则安装锁定依赖
      - node  ：若存在 package.json 且有 package-lock.json 则 npm ci 安装锁定依赖
      - binary：仅检查本地二进制（<服务Id>.exe）是否就位
    环境目录均在 .gitignore 忽略范围内，不污染全局 Python/Node。

    用法：
      scripts\bootstrap.ps1                # 初始化缺失环境（已就绪跳过）
      scripts\bootstrap.ps1 -Check         # 仅检查环境，不做任何变更
      scripts\bootstrap.ps1 -Rebuild       # 删除现有环境后重建
      scripts\bootstrap.ps1 -ServiceCode A # 只处理指定服务

    占位状态下（无锁定文件/二进制）流程可跑通，缺失项给出中文原因与下一步。
#>

. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\registry.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\service-utils.ps1')

$script:McpBootstrapAction = @{
    Ready      = '已就绪'
    Created    = '已创建'
    Skipped    = '已跳过'
    Failed     = '失败'
    Missing    = '未初始化'
}

function Invoke-McpNative {
    <# 运行外部命令并吞掉 stderr 重定向的 ErrorRecord（避免调用方
       $ErrorActionPreference='Stop' 时 5.1 将 stderr 误判为终止错误）。
       返回 ExitCode 与合并输出。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $code; Output = ($out | Out-String) }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Resolve-McpPythonLauncher {
    <# 返回实测可用的 Python 启动器数组（如 @('C:\...\py.exe','-3')）。
       候选：py -3、python、python3（Microsoft Store 存根与 WindowsApps 下的
       发行版均排除——受限环境无法从 WindowsApps 创建进程）。每个候选实际
       运行 --version 验证；全部失败返回 $null。 #>
    $candidates = @()
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py -and $py.Source -notmatch 'WindowsApps') {
        $candidates += , @($py.Source, '-3')
    }
    foreach ($name in @('python', 'python3')) {
        $pp = Get-Command $name -ErrorAction SilentlyContinue
        if ($pp -and $pp.Source -notmatch 'WindowsApps') {
            $candidates += , @($pp.Source)
        }
    }
    foreach ($cand in $candidates) {
        $pyArgs = @()
        if ($cand.Count -gt 1) { $pyArgs = $cand[1..($cand.Count - 1)] }
        $probe = Invoke-McpNative -FilePath $cand[0] -ArgumentList @($pyArgs + @('--version'))
        if ($probe.ExitCode -eq 0 -and $probe.Output -match 'Python') {
            return , $cand
        }
    }
    return $null
}

function Test-McpNodeToolchain {
    <# 检查 node / npm 是否可用，返回 npm 可执行对象（$null 表示不可用）。
       Windows 下优先 npm.cmd（npm.ps1 受执行策略影响，5.1 下可能被拦）。 #>
    $node = Get-Command node -ErrorAction SilentlyContinue
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if ($null -eq $node -or $null -eq $npm -or $node.Source -match 'WindowsApps') {
        return $null
    }
    return $npm
}

function Invoke-McpBootstrap {
    [CmdletBinding()]
    param(
        [switch]$Check,
        [switch]$Rebuild,
        [string]$Code
    )

    $services = Get-McpServices
    if ($Code) {
        $svc = Get-McpServiceByCode -Code $Code
        if (-not $svc) { throw "未知的服务代号：$Code" }
        $services = @($svc)
    }

    Write-Host '=============================================='
    if ($Check) { Write-Host '  Bootstrap：仅检查环境（不做变更）' }
    elseif ($Rebuild) { Write-Host '  Bootstrap：重建环境（先删除再初始化）' }
    else { Write-Host '  Bootstrap：初始化缺失环境' }
    Write-Host '=============================================='

    $results = @()
    foreach ($svc in $services) {
        $action = $script:McpBootstrapAction.Missing
        $note = ''
        $failed = $false
        # 服务子目录名即服务 Id（仓库约定，见 registry.ps1 判重规则）
        $svcDir = Join-Path (Get-McpRepoRoot) $svc.Id

        switch ($svc.Stack) {
            'python' {
                $venvDir = Join-Path $svcDir 'venv'
                $venvPy = Join-Path $venvDir 'Scripts\python.exe'
                $reqFile = Join-Path $svcDir 'requirements.txt'

                if ($Rebuild -and (Test-Path -LiteralPath $venvDir)) {
                    Remove-Item -LiteralPath $venvDir -Recurse -Force
                    Write-Host ("[{0}] 已删除旧环境：{1}" -f $svc.DisplayName, $venvDir)
                }

                if (Test-Path -LiteralPath $venvPy) {
                    $action = $script:McpBootstrapAction.Ready
                    $note = 'venv 已存在'
                }
                elseif ($Check) {
                    $action = $script:McpBootstrapAction.Missing
                    $note = 'venv 未创建'
                }
                else {
                    $launcher = Resolve-McpPythonLauncher
                    if (-not $launcher) {
                        $action = $script:McpBootstrapAction.Failed
                        $note = '未找到实测可用的 Python（Microsoft Store 版在受限环境不可用）。下一步：安装常规发行版 Python 3.8+（python.org）后重跑'
                        $failed = $true
                    }
                    else {
                        $pyArgs = @()
                        if ($launcher.Count -gt 1) { $pyArgs = $launcher[1..($launcher.Count - 1)] }
                        Write-Host ("[{0}] 正在创建 venv（{1}）…" -f $svc.DisplayName, (Split-Path -Leaf $launcher[0]))
                        $venvRes = Invoke-McpNative -FilePath $launcher[0] -ArgumentList @($pyArgs + @('-m', 'venv', $venvDir))
                        if ($venvRes.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $venvPy)) {
                            $action = $script:McpBootstrapAction.Failed
                            $note = 'venv 创建失败。下一步：安装常规发行版 Python 3.8+（python.org）后重跑；Microsoft Store 版 Python 在部分受限环境无法启动'
                            $failed = $true
                        }
                        elseif (Test-Path -LiteralPath $reqFile) {
                            Write-Host ("[{0}] 正在安装锁定依赖（requirements.txt）…" -f $svc.DisplayName)
                            $pipRes = Invoke-McpNative -FilePath $venvPy -ArgumentList @('-m', 'pip', 'install', '-r', $reqFile, '--disable-pip-version-check', '--no-input', '-q')
                            if ($pipRes.ExitCode -ne 0) {
                                $action = $script:McpBootstrapAction.Failed
                                $note = '依赖安装失败。下一步：检查网络与 requirements.txt 后重跑（或 -Rebuild 重建）'
                                $failed = $true
                            }
                            else {
                                $action = $script:McpBootstrapAction.Created
                                $note = 'venv 创建并安装锁定依赖完成'
                            }
                        }
                        else {
                            $action = $script:McpBootstrapAction.Created
                            $note = 'venv 创建完成（暂无 requirements.txt，服务接入里程碑回填后重跑安装依赖）'
                        }
                    }
                }
            }
            'node' {
                $pkgFile = Join-Path $svcDir 'package.json'
                $lockFile = Join-Path $svcDir 'package-lock.json'
                $nmDir = Join-Path $svcDir 'node_modules'

                if ($Rebuild -and (Test-Path -LiteralPath $nmDir)) {
                    Remove-Item -LiteralPath $nmDir -Recurse -Force
                    Write-Host ("[{0}] 已删除旧依赖目录：{1}" -f $svc.DisplayName, $nmDir)
                }

                if (-not (Test-Path -LiteralPath $pkgFile)) {
                    if ($Check) {
                        $action = $script:McpBootstrapAction.Missing
                        $note = 'package.json 尚未提供'
                    }
                    else {
                        $action = $script:McpBootstrapAction.Skipped
                        $note = 'package.json 尚未提供（服务接入里程碑回填后重跑）'
                    }
                }
                elseif (Test-Path -LiteralPath $nmDir) {
                    $action = $script:McpBootstrapAction.Ready
                    $note = 'node_modules 已存在'
                }
                elseif ($Check) {
                    $action = $script:McpBootstrapAction.Missing
                    $note = '依赖目录未创建'
                }
                elseif (-not (Test-Path -LiteralPath $lockFile)) {
                    $action = $script:McpBootstrapAction.Skipped
                    $note = '缺少 package-lock.json（要求锁定安装），暂不安装。下一步：服务接入里程碑提供锁定文件后重跑'
                }
                elseif (-not ($npmExe = Test-McpNodeToolchain)) {
                    $action = $script:McpBootstrapAction.Failed
                    $note = '未找到可用的 node/npm。下一步：安装 Node.js LTS 后重跑'
                    $failed = $true
                }
                else {
                    Write-Host ("[{0}] 正在按锁定文件安装依赖（npm ci）…" -f $svc.DisplayName)
                    Push-Location $svcDir
                    try {
                        $npmRes = Invoke-McpNative -FilePath $npmExe.Source -ArgumentList @('ci', '--no-audit', '--no-fund', '--loglevel=error')
                    }
                    finally {
                        Pop-Location
                    }
                    if ($npmRes.ExitCode -ne 0) {
                        $action = $script:McpBootstrapAction.Failed
                        $note = 'npm ci 安装失败。下一步：检查网络与 package-lock.json 后重跑'
                        $failed = $true
                    }
                    else {
                        $action = $script:McpBootstrapAction.Created
                        $note = '依赖按锁定文件安装完成'
                    }
                }
            }
            'binary' {
                $binFile = Join-Path $svcDir ("{0}.exe" -f $svc.Id)
                if (Test-Path -LiteralPath $binFile) {
                    $action = $script:McpBootstrapAction.Ready
                    $note = '本地二进制已就位'
                }
                elseif ($Check) {
                    $action = $script:McpBootstrapAction.Missing
                    $note = '本地二进制未放置'
                }
                else {
                    $action = $script:McpBootstrapAction.Skipped
                    $note = '本地二进制未放置（服务接入里程碑提供获取脚本或说明后按指引放置）'
                }
            }
            default {
                $action = $script:McpBootstrapAction.Failed
                $note = "未知技术栈：$($svc.Stack)"
                $failed = $true
            }
        }

        $results += [pscustomobject]@{
            Code   = $svc.Code
            Id     = $svc.Id
            Stack  = $svc.Stack
            Action = $action
            Failed = $failed
            Note   = $note
        }
    }

    Write-Host ''
    Write-Host '========== Bootstrap 结果汇总 =========='
    $results | Format-Table -AutoSize @(
        @{ Label = '代号'; Expression = { $_.Code } },
        @{ Label = '服务'; Expression = { $_.Id } },
        @{ Label = '技术栈'; Expression = { $_.Stack } },
        @{ Label = '结果'; Expression = { $_.Action } },
        @{ Label = '说明'; Expression = { $_.Note } }
    ) | Out-Host

    foreach ($r in $results) {
        Write-McpOpsLog -Action ('Bootstrap/' + $r.Action) -Service $r.Id -Detail $r.Note
    }

    # @() 强制数组化：Windows PowerShell 5.1 下 Where-Object 输出单个 PSCustomObject 时 .Count 为 $null
    $failCount = @($results | Where-Object { $_.Failed }).Count
    if ($Check) {
        Write-Host '检查完成（仅检查模式不做任何变更）。'
        return 0
    }
    if ($failCount -gt 0) {
        Write-Host ("Bootstrap 完成：{0} 项失败，请按上方说明处理后重跑。" -f $failCount)
        return 1
    }
    Write-Host 'Bootstrap 完成：全部服务处理成功或按占位跳过。'
    return 0
}

# 直接运行时执行；被 dot-source 时不触发
if ($MyInvocation.InvocationName -ne '.') {
    $bootstrapResult = Invoke-McpBootstrap @PSBoundParameters
    exit ([int]$bootstrapResult)
}
