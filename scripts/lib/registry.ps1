#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 注册表读取基础函数（M1）。

.DESCRIPTION
    提供 mcpctl 各脚本（配置向导 / 启停管理 / Bootstrap 等）复用的基础函数：
    加载配置、读取服务条目、按代号或目录名检索、解析仓库相对路径为绝对路径。

    用法：在脚本头部 dot-source 本文件即可：
        . (Join-Path $PSScriptRoot 'lib\registry.ps1')

.NOTES
    本文件只提供【读取类】基础函数；启动/停止等业务逻辑见后续里程碑（M3+）。
#>

# 加载数据源（服务注册表与全局参数）
. (Join-Path -Path $PSScriptRoot -ChildPath '..\mcpctl.config.ps1')

<#
.SYNOPSIS
    获取仓库根目录（绝对路径）。
#>
function Get-McpRepoRoot {
    return $script:McpCtlGlobal.RepoRoot
}

<#
.SYNOPSIS
    获取全局参数（含优雅停止超时、菜单语言等）。

.OUTPUTS
    System.Collections.Hashtable
#>
function Get-McpGlobalConfig {
    return $script:McpCtlGlobal
}

<#
.SYNOPSIS
    获取全部服务注册表条目。

.DESCRIPTION
    将注册表哈希表转换为 PSCustomObject 列表返回；每条目额外附加
    *Full 后缀的绝对路径字段（基于仓库根解析），供后续脚本直接使用。

.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-McpServices {
    $root = $script:McpCtlGlobal.RepoRoot
    foreach ($svc in $script:McpServices) {
        [pscustomobject]@{
            Code                  = $svc.Code
            Id                    = $svc.Id
            DisplayName           = $svc.DisplayName
            StartCommand          = $svc.StartCommand
            Stack                 = $svc.Stack
            ConfigTemplate        = $svc.ConfigTemplate
            ConfigTemplateFull    = (Join-Path $root $svc.ConfigTemplate)
            LocalConfig           = $svc.LocalConfig
            LocalConfigFull       = (Join-Path $root $svc.LocalConfig)
            PidFile               = $svc.PidFile
            PidFileFull           = (Join-Path $root $svc.PidFile)
            LogFile               = $svc.LogFile
            LogFileFull           = (Join-Path $root $svc.LogFile)
        }
    }
}

<#
.SYNOPSIS
    按服务代号（A/B/C/D）检索服务条目。

.PARAMETER Code
    服务代号，不区分大小写。
#>
function Get-McpServiceByCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )
    Get-McpServices | Where-Object { $_.Code -eq $Code.ToUpperInvariant() }
}

<#
.SYNOPSIS
    按子目录名（如 mcp-jenkins）检索服务条目。

.PARAMETER Id
    子目录名，不区分大小写。
#>
function Get-McpServiceById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )
    Get-McpServices | Where-Object { $_.Id -eq $Id.ToLowerInvariant() }
}

<#
.SYNOPSIS
    校验注册表数据完整性（自检用）。

.DESCRIPTION
    检查每个条目的 9 个必填字段是否存在且合法（代号/子目录名唯一、
    相对路径不含 .. 越级等）。返回不合规条目列表，全部合规时返回空数组。

.OUTPUTS
    System.String[]  # 违规描述；为空表示全部合规
#>
function Test-McpRegistry {
    $requiredFields = @('Code','Id','DisplayName','StartCommand','ConfigTemplate','LocalConfig','PidFile','LogFile','Stack')
    $knownStacks = @('python','node','binary')
    $problems = @()

    $codes = @()
    $ids = @()
    foreach ($svc in $script:McpServices) {
        foreach ($f in $requiredFields) {
            if (-not $svc.ContainsKey($f)) {
                $problems += ("条目 {0}: 缺少字段 {1}" -f $svc['Id'], $f)
            }
        }
        $codes += $svc['Code']
        $ids += $svc['Id']
        if ($knownStacks -notcontains $svc['Stack']) {
            $problems += ("条目 {0}: 未知技术栈 {1}（允许：{2}）" -f $svc['Id'], $svc['Stack'], ($knownStacks -join '/'))
        }
        foreach ($p in @('ConfigTemplate','LocalConfig','PidFile','LogFile')) {
            if ($svc.ContainsKey($p) -and ($svc[$p] -match '\.\.[\\/]' -or [IO.Path]::IsPathRooted($svc[$p]))) {
                $problems += ("条目 {0}: {1} 必须是不越级的仓库相对路径，当前为 {2}" -f $svc['Id'], $p, $svc[$p])
            }
        }
    }
    $dupCodes = $codes | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupCodes) { $problems += ("服务代号重复：{0}" -f (($dupCodes | ForEach-Object Name) -join ', ')) }
    $dupIds = $ids | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupIds) { $problems += ("子目录名重复：{0}" -f (($dupIds | ForEach-Object Name) -join ', ')) }

    return $problems
}
