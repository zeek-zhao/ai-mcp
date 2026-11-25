#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 总控主菜单（M3 骨架）。

.DESCRIPTION
    全中文交互菜单，当前接入：
      1. 启动服务（批量/单选，只启动配置就绪的服务）
      2. 停止服务（批量/单选，通知 → 等待 → 确认 → 强制）
      3. 查看状态（表格）
      4. 服务配置向导（M2）
    其余能力（Bootstrap 环境 / 各服务接入 / 登录常驻 / Host 配置导出）
    按里程碑占位（M4、M5–M10 提供）。

    运行：pwsh / powershell 下执行 scripts\mcpctl.ps1。
#>

# 加载核心库（注册表 / 配置向导 / 启停工具 / Bootstrap）
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\service-utils.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\config-wizard.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'bootstrap.ps1')

function Show-McpMenu {
    Clear-Host
    Write-Host '=============================================='
    Write-Host '        MCP 服务总控（mcpctl）'
    Write-Host ('        仓库：' + (Get-McpRepoRoot))
    Write-Host '=============================================='
    Write-Host '  [1] 启动服务（批量 / 单选）'
    Write-Host '  [2] 停止服务（批量 / 单选）'
    Write-Host '  [3] 查看服务状态'
    Write-Host '  [4] 服务配置向导'
    Write-Host '  [5] 初始化运行环境（Bootstrap：检查 / 初始化 / 重建）'
    Write-Host '  [6] 各服务接入管理 —— 待 M5–M8 提供'
    Write-Host '  [7] 登录常驻管理 —— 待 M9 提供'
    Write-Host '  [8] Host 配置导出 —— 待 M10 提供'
    Write-Host '  [0] 退出'
    Write-Host '----------------------------------------------'
}

function Invoke-McpctlMenu {
    while ($true) {
        Show-McpMenu
        $choice = Read-Host '请选择操作 [0-8]'
        switch ($choice) {
            '1' {
                $scope = Read-Host '启动范围：[1] 全部就绪服务 [2] 指定服务（输入代号 A-D）'
                if ($scope -eq '2') {
                    $c = Read-Host '请输入服务代号'
                    Start-McpServices -Code $c | Out-Null
                }
                else {
                    Start-McpServices | Out-Null
                }
            }
            '2' {
                $scope = Read-Host '停止范围：[1] 全部运行中服务 [2] 指定服务（输入代号 A-D）'
                if ($scope -eq '2') {
                    $c = Read-Host '请输入服务代号'
                    Stop-McpServices -Code $c | Out-Null
                }
                else {
                    Stop-McpServices | Out-Null
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
            '6' { Write-Host '（占位）各服务接入将在 M5–M8 提供。' }
            '7' { Write-Host '（占位）登录常驻管理将在 M9 提供。' }
            '8' { Write-Host '（占位）Host 配置导出将在 M10 提供。' }
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
