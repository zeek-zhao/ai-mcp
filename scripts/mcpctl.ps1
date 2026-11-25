#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 总控主菜单（传输模型整改后：Host 拉起 stdio，见 ADR-006）。

.DESCRIPTION
    全中文交互菜单。模型一下 mcpctl 不再后台托管服务进程，只做治理：
      1. 服务诊断与自检（启动命令 / 配置 / 依赖环境 + 可选 MCP 握手探活）
      2. 清理遗留进程（二次确认，taskkill /F /T 强杀进程树）
      3. 查看服务状态（配置就绪 / 依赖环境 / 启动命令 / 遗留进程 / 日志位置）
      4. 服务配置向导（M2）
      5. 初始化运行环境 Bootstrap（M4：检查 / 初始化 / 重建）
      6. 导出 Host 配置（stdio 配置片段写入仓库外本地文件，不含明文凭证）
      7. 登录预检（占位，M9 按“登录预检与环境自愈”重定义后提供）
    MCP 服务本体由 Host（Cursor / Claude Desktop 等）按需 stdio 拉起，
    mcpctl 不启动、不停止、不托管服务进程。

    运行：pwsh / powershell 下执行 scripts\mcpctl.ps1。
#>

# 加载核心库（注册表 / 配置向导 / 诊断与遗留进程治理 / Bootstrap）
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\service-utils.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\config-wizard.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'bootstrap.ps1')

function Show-McpMenu {
    Clear-Host
    Write-Host '=============================================='
    Write-Host '        MCP 服务总控（mcpctl）'
    Write-Host ('        仓库：' + (Get-McpRepoRoot))
    Write-Host '  模型：服务由 Host 按需 stdio 拉起，本工具只做治理'
    Write-Host '=============================================='
    Write-Host '  [1] 服务诊断与自检（含握手探活入口）'
    Write-Host '  [2] 清理遗留进程（二次确认强杀）'
    Write-Host '  [3] 查看服务状态'
    Write-Host '  [4] 服务配置向导'
    Write-Host '  [5] 初始化运行环境（Bootstrap：检查 / 初始化 / 重建）'
    Write-Host '  [6] 导出 Host 配置（stdio 片段，本地文件）'
    Write-Host '  [7] 登录预检 —— 待 M9 提供'
    Write-Host '  [0] 退出'
    Write-Host '----------------------------------------------'
}

<#
.SYNOPSIS
    导出 Host stdio 配置片段到本地文件（默认仓库外，不含明文凭证）。
#>
function Invoke-McpHostConfigExport {
    $defaultPath = Join-Path $env:USERPROFILE 'mcp-host-config.json'
    $target = Read-Host ("输出文件路径（默认：{0}）" -f $defaultPath)
    if (-not $target) { $target = $defaultPath }

    $servers = [ordered]@{}
    foreach ($svc in (Get-McpServices)) {
        $ready = (Get-McpConfigReadiness -Code $svc.Code | Select-Object -First 1)
        $entry = [ordered]@{}
        if (Test-McpStartCommandFilled -Service $svc) {
            $entry['command'] = "$($svc.StartCommand[0])"
            $argsArr = @()
            if ($svc.StartCommand.Count -gt 1) { $argsArr = @($svc.StartCommand[1..($svc.StartCommand.Count - 1)]) }
            $entry['args'] = $argsArr
        }
        else {
            $entry['command'] = "<待 M5–M8 接入里程碑回填>"
            $entry['args'] = @()
        }
        # env 不导出（凭证只保存在本地配置文件，绝不写明文到导出文件）
        $entry['note'] = ("配置文件：{0}（{1}；凭证仅保存在该本地文件）" -f $svc.LocalConfig,
            $(if ($ready.Ready) { '已就绪' } else { '未就绪，请先运行 mcpctl 配置向导' }))
        $servers[$svc.Id] = $entry
    }

    $doc = [ordered]@{
        '_说明' = 'Host（Cursor / Claude Desktop 等）stdio 拉起配置片段；服务由 Host 按需启动，mcpctl 不托管进程。'
        'mcpServers' = $servers
    }
    $json = $doc | ConvertTo-Json -Depth 10
    $targetDir = Split-Path -Parent $target
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($target, $json, $utf8NoBom)
    Write-Host ("已导出 Host 配置片段：{0}（仓库外文件，不含明文凭证）" -f $target)
    Write-McpOpsLog -Action '导出Host配置' -Service '-' -Detail $target
}

function Invoke-McpctlMenu {
    while ($true) {
        Show-McpMenu
        $choice = Read-Host '请选择操作 [0-7]'
        switch ($choice) {
            '1' {
                Show-McpServiceDiagnostics
                $probe = Read-Host '是否对某服务执行 MCP 握手探活？输入代号（A-D），回车跳过'
                if ($probe) {
                    $svc = Get-McpServiceByCode -Code $probe
                    if (-not $svc) { Write-Host ("未知的服务代号：{0}" -f $probe) }
                    else { Invoke-McpHandshakeProbe -Service $svc | Out-Null }
                }
            }
            '2' {
                $scope = Read-Host '清理范围：[1] 全部服务 [2] 指定服务（输入代号 A-D）'
                if ($scope -eq '2') {
                    $c = Read-Host '请输入服务代号'
                    Invoke-McpLeftoverCleanup -Code $c | Out-Null
                }
                else {
                    Write-Host '将对全部服务检测并清理遗留进程（强杀前逐个二次确认）。'
                    Invoke-McpLeftoverCleanup | Out-Null
                }
            }
            '3' {
                Show-McpServiceStatus
            }
            '4' {
                Invoke-McpConfigWizard
            }
            '5' {
                $mode = Read-Host 'Bootstrap 模式：[1] 仅检查环境 [2] 初始化缺失环境 [3] 重建环境'
                switch ($mode) {
                    '1' { Invoke-McpBootstrap -Check | Out-Null }
                    '3' { Invoke-McpBootstrap -Rebuild | Out-Null }
                    default { Invoke-McpBootstrap | Out-Null }
                }
            }
            '6' {
                Invoke-McpHostConfigExport
            }
            '7' { Write-Host '（占位）登录预检与环境自愈将在 M9 提供（原“登录常驻”已取消，理由见 ADR-006）。' }
            '0' { return }
            default { Write-Host '输入无效，请重新选择。' }
        }
        if ($choice -ne '0') {
            Read-Host '按回车返回主菜单' | Out-Null
        }
    }
}

# 直接运行时进入菜单；被 dot-source 时不触发
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-McpctlMenu
}
