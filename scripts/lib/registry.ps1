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
    本文件只提供【读取类】基础函数；服务进程不由 mcpctl 托管（ADR-006），诊断与握手探活见 service-utils.ps1。
    Test-McpRegistry 会校验注册表的 ConfigKey 与统一配置模板 mcp.config.sample.json 的 services 键一致。
    仓库根目录的来源（T-ENV-01）：环境变量 MCP_SUITE_ROOT（仓库根目录的绝对路径）优先，未设置时由脚本自身位置推断；
    已设置但无效时不静默回退——Get-McpRepoRoot 抛出中文错误，登录预检把它作为单独的未通过项报告。
#>

# 加载数据源（服务注册表与全局参数）
. (Join-Path -Path $PSScriptRoot -ChildPath '..\mcpctl.config.ps1')

# ---------------------------------------------------------------------------
# 仓库根目录来源（T-ENV-01）
#   优先级：环境变量 MCP_SUITE_ROOT > 由脚本自身位置推断（scripts 的上一级）。
#   环境变量已设置但无效时【不静默回退】：Get-McpRepoRoot 一经调用即抛出中文错误（含清除命令）。
#   四个启动器（mcp-*/launcher.*）按同一优先级定位统一配置，报错文案与本处保持逐字一致（CI 校验）。
# ---------------------------------------------------------------------------
$script:McpRepoRootEnvName = 'MCP_SUITE_ROOT'
$script:McpRepoRootSourceText = '由脚本位置推断'
$script:McpRepoRootIssue = ''
$script:McpRepoRootResolved = $script:McpCtlGlobal.RepoRoot
$script:McpRepoRootClearCommand = 'setx MCP_SUITE_ROOT ""'
$script:McpRepoRootNotAbsolutePattern = '环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：{0}。请改为正确的仓库根目录，或清除该变量后重试：{1}'
$script:McpRepoRootNotRepoPattern = '环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：{0}。请改为正确的仓库根目录，或清除该变量后重试：{1}'
$mcpRepoRootRaw = [Environment]::GetEnvironmentVariable($script:McpRepoRootEnvName)
if (-not [string]::IsNullOrWhiteSpace($mcpRepoRootRaw)) {
    $mcpRepoRootValue = $mcpRepoRootRaw.Trim()
    if (-not [IO.Path]::IsPathRooted($mcpRepoRootValue)) {
        $script:McpRepoRootIssue = $script:McpRepoRootNotAbsolutePattern -f @($mcpRepoRootValue, $script:McpRepoRootClearCommand)
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $mcpRepoRootValue 'scripts\mcpctl.config.ps1') -PathType Leaf)) {
        $script:McpRepoRootIssue = $script:McpRepoRootNotRepoPattern -f @($mcpRepoRootValue, $script:McpRepoRootClearCommand)
    }
    else {
        $script:McpRepoRootResolved = (Resolve-Path -LiteralPath $mcpRepoRootValue).ProviderPath
        $script:McpRepoRootSourceText = '来自环境变量 MCP_SUITE_ROOT'
    }
}
Remove-Variable -Name mcpRepoRootRaw, mcpRepoRootValue -ErrorAction SilentlyContinue

<#
.SYNOPSIS
    获取仓库根目录（绝对路径）。

.DESCRIPTION
    来源优先级：环境变量 MCP_SUITE_ROOT > 由脚本自身位置推断。
    环境变量已设置但无效时抛出中文错误（不回退到脚本位置）；调用方需要“只判断不抛错”时用 Get-McpRepoRootIssue。
#>
function Get-McpRepoRoot {
    if ($script:McpRepoRootIssue) { throw $script:McpRepoRootIssue }
    return $script:McpRepoRootResolved
}

<#
.SYNOPSIS
    获取仓库根目录的来源说明（用于启动时打印“[根路径] …”）。
#>
function Get-McpRepoRootSourceText {
    if ($script:McpRepoRootIssue) { throw $script:McpRepoRootIssue }
    return $script:McpRepoRootSourceText
}

<#
.SYNOPSIS
    环境变量 MCP_SUITE_ROOT 已设置但无效时返回错误说明（中文，含修复办法），有效或未设置时返回空字符串。不抛错。
#>
function Get-McpRepoRootIssue {
    return $script:McpRepoRootIssue
}

<#
.SYNOPSIS
    清除环境变量 MCP_SUITE_ROOT 的命令（供错误提示与修复建议引用）。
#>
function Get-McpRepoRootClearCommand {
    return $script:McpRepoRootClearCommand
}

<#
.SYNOPSIS
    获取全局参数（含进程退出等待超时、菜单语言等）。

.OUTPUTS
    System.Collections.Hashtable
#>
function Get-McpGlobalConfig {
    return $script:McpCtlGlobal
}

<#
.SYNOPSIS
    将注册表的仓库相对路径 StartCommand 归一化为可执行形态（唯一实现点）。

.DESCRIPTION
    规则（内存中归一化，注册表文件仍保存相对路径）：
      [0] command：
        - 已是绝对路径 → 原样返回；
        - 否则若 <仓库根>/<command> 存在 → 转为绝对路径；
        - 否则若可在 PATH 中命中（如 node）→ 保留原名，交给 PATH 解析；
        - 否则原样保留，由诊断给出“不可定位”提示。
      [1..n] args：
        - 以 '-' 开头（如 --config）、或已是绝对路径 → 原样保留；
        - 其余若 <仓库根>/<arg> 存在（如配置文件、launcher.py）→ 转为绝对路径；
        - 其余（如 stdio）原样保留。

    诊断、握手探活、Host 配置导出三处共用本函数，不得各自重复实现。
#>
function Resolve-McpStartCommand {
    [CmdletBinding()]
    param([AllowNull()]$Command)

    if (-not $Command) { return $null }
    $root = Get-McpRepoRoot
    $parts = @($Command)
    $resolved = @()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = "$($parts[$i])".Trim()
        if (-not $part) { continue }
        if ([IO.Path]::IsPathRooted($part) -or ($i -gt 0 -and $part.StartsWith('-'))) {
            $resolved += $part
            continue
        }
        $repoPath = Join-Path $root $part
        if (Test-Path -LiteralPath $repoPath) {
            $resolved += (Resolve-Path -LiteralPath $repoPath).ProviderPath
        }
        elseif ($i -eq 0 -and (Get-Command $part -ErrorAction SilentlyContinue)) {
            $resolved += $part   # PATH 命令（如 node）保留原名
        }
        else {
            $resolved += $part
        }
    }
    return $resolved
}

<#
.SYNOPSIS
    获取全部服务注册表条目。

.DESCRIPTION
    将注册表哈希表转换为 PSCustomObject 列表返回；每条目额外附加
    *Full 后缀的绝对路径字段（基于仓库根解析），供后续脚本直接使用。
    StartCommand 输出前经 Resolve-McpStartCommand 归一化（仓库内相对路径
    转绝对路径，PATH 命令保留原名）。ConfigKey 为统一配置 mcp.config.json 中
    services 下的段名，配置内容的读写见 suite-config.ps1。

.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-McpServices {
    $root = Get-McpRepoRoot
    foreach ($svc in $script:McpServices) {
        [pscustomobject]@{
            Code                  = $svc.Code
            Id                    = $svc.Id
            DisplayName           = $svc.DisplayName
            StartCommand          = (Resolve-McpStartCommand -Command $svc.StartCommand)
            ConfigKey             = $svc.ConfigKey
            Stack                 = $svc.Stack
            BinaryPath            = $svc['BinaryPath']
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
        [AllowEmptyString()]
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
        [AllowEmptyString()]
        [string]$Id
    )
    Get-McpServices | Where-Object { $_.Id -eq $Id.ToLowerInvariant() }
}

<#
.SYNOPSIS
    获取某服务在注册表中的原始 StartCommand（仓库相对路径数组，不做路径归一化）。

.DESCRIPTION
    供需要「按另一个仓库根重新拼路径」的调用方使用（如网关路由生成，T-ENV-02）；
    服务不存在时返回 $null。

.OUTPUTS
    System.String[]
#>
function Get-McpRawStartCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)

    foreach ($svc in $script:McpServices) {
        if ($svc.Id -eq $Id.ToLowerInvariant()) { return @($svc.StartCommand | ForEach-Object { "$_" }) }
    }
    return $null
}

<#
.SYNOPSIS
    校验注册表数据完整性（自检用）。

.DESCRIPTION
    检查每个条目的 8 个必填字段是否存在且合法（代号/子目录名/ConfigKey 唯一、
    相对路径不越级等），并校验 ConfigKey 与统一配置模板 mcp.config.sample.json
    的 services 键双向一致。返回不合规描述列表，全部合规时返回空数组。

.OUTPUTS
    System.String[]  # 违规描述；为空表示全部合规
#>
function Test-McpRegistry {
    $requiredFields = @('Code','Id','DisplayName','StartCommand','ConfigKey','PidFile','LogFile','Stack')
    $knownStacks = @('python','node','binary')
    $problems = @()

    $codes = @()
    $ids = @()
    $keys = @()
    foreach ($svc in $script:McpServices) {
        foreach ($f in $requiredFields) {
            if (-not $svc.ContainsKey($f) -or [string]::IsNullOrWhiteSpace("$($svc[$f])")) {
                $problems += ("条目 {0}: 缺少字段 {1}" -f $svc['Id'], $f)
            }
        }
        $codes += $svc['Code']
        $ids += $svc['Id']
        if ($svc.ContainsKey('ConfigKey') -and $svc['ConfigKey']) { $keys += "$($svc['ConfigKey'])".ToLowerInvariant() }
        if ($knownStacks -notcontains $svc['Stack']) {
            $problems += ("条目 {0}: 未知技术栈 {1}（允许：{2}）" -f $svc['Id'], $svc['Stack'], ($knownStacks -join '/'))
        }
        foreach ($p in @('PidFile','LogFile')) {
            if ($svc.ContainsKey($p) -and ($svc[$p] -match '\.\.[\\/]' -or [IO.Path]::IsPathRooted($svc[$p]))) {
                $problems += ("条目 {0}: {1} 必须是不越级的仓库相对路径，当前为 {2}" -f $svc['Id'], $p, $svc[$p])
            }
        }
    }
    $dupCodes = $codes | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupCodes) { $problems += ("服务代号重复：{0}" -f (($dupCodes | ForEach-Object Name) -join ', ')) }
    $dupIds = $ids | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupIds) { $problems += ("子目录名重复：{0}" -f (($dupIds | ForEach-Object Name) -join ', ')) }
    $dupKeys = $keys | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupKeys) { $problems += ("ConfigKey 重复：{0}" -f (($dupKeys | ForEach-Object Name) -join ', ')) }

    # 全局参数：统一配置路径必须是不越级的仓库相对路径
    $global = $script:McpCtlGlobal
    $suitePath = if ($global.ContainsKey('SuiteConfigPath')) { "$($global['SuiteConfigPath'])" } else { '' }
    if ([string]::IsNullOrWhiteSpace($suitePath) -or $suitePath -match '\.\.[\\/]' -or [IO.Path]::IsPathRooted($suitePath)) {
        $problems += "全局参数 SuiteConfigPath 必须是不越级的仓库相对路径，当前为：$suitePath"
    }

    # ConfigKey 与统一配置模板的 services 键双向一致
    $sampleRelative = 'mcp.config.sample.json'
    $samplePath = Join-Path (Get-McpRepoRoot) $sampleRelative
    $sampleKeys = @()
    if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) {
        $problems += "统一配置模板不存在：$sampleRelative"
    }
    else {
        try {
            $sample = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($samplePath, [Text.Encoding]::UTF8)) -ErrorAction Stop
            if ($sample.services) {
                $sampleKeys = @($sample.services.PSObject.Properties | ForEach-Object { $_.Name.ToLowerInvariant() })
            }
        }
        catch {
            $problems += "统一配置模板不是合法 JSON：$sampleRelative"
        }
        foreach ($k in $keys) {
            if ($sampleKeys.Count -gt 0 -and $sampleKeys -notcontains $k) {
                $problems += ("ConfigKey {0} 在 {1} 的 services 中不存在" -f $k, $sampleRelative)
            }
        }
        foreach ($k in $sampleKeys) {
            if ($keys -notcontains $k) {
                $problems += ("{0} 的 services.{1} 在注册表中没有对应条目" -f $sampleRelative, $k)
            }
        }
    }

    return $problems
}
