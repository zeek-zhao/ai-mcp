#Requires -Version 5.1
<#
.SYNOPSIS
    Magpie 网关路由配置生成（T-ENV-02）：按注册表 StartCommand 生成本机 gateway.routes.json，并给出登记命令。

.DESCRIPTION
    约定（菜单 8 与 CI 自检共用本模块，不得另写一套）：
      1. 与样例 gateway.routes.sample.json 同构：顶层只有 mcpServers；服务名固定（Gerrit / GitHub / Jenkins / Atlassian，不加前缀）。
      2. command / args 来自注册表 StartCommand（仓库相对路径）：含路径分隔符或带脚本扩展名的项拼上仓库根的绝对路径，
         PATH 命令（如 node）与以 '-' 开头的参数原样保留。样例中对应位置写作 ${MCP_SUITE_ROOT} 占位符。
      3. env 只放 MCP_SUITE_CONFIG（统一配置文件的本机绝对路径）。凭证只保存在统一配置文件里，本模块不读取其内容。
      4. 生成结果含本机绝对路径，只能保存在仓库根的 gateway.routes.json（或带时间戳的副本），已被 .gitignore 排除，不得入库。

    Magpie 登记命令的参数写法以本机 CLI 实测为准（0.1.4572）：
      magpie library mcp add <服务名> --local "env=MCP_SUITE_CONFIG=<统一配置绝对路径>" -- "<command>" "<args…>"
#>

# 依赖注册表（Get-McpServices）与统一配置模块的 JSON 序列化；被 mcpctl.ps1 加载时已就绪
if (-not (Get-Command Get-McpServices -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'registry.ps1')
}
if (-not (Get-Command ConvertTo-McpJsonString -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'suite-config.ps1')
}

# 注册表 Id → Magpie 服务名（固定，区分大小写）。新增服务时须在此登记，并同步 gateway.routes.sample.json
$script:McpGatewayNames = [ordered]@{
    'mcp-gerrit'    = 'Gerrit'
    'mcp-github'    = 'GitHub'
    'mcp-jenkins'   = 'Jenkins'
    'mcp-atlassian' = 'Atlassian'
}
$script:McpGatewayFileName = 'gateway.routes.json'
$script:McpGatewayConfigEnvName = 'MCP_SUITE_CONFIG'
$script:McpGatewayConfigFileName = 'mcp.config.json'
$script:McpGatewayPlaceholder = '${MCP_SUITE_ROOT}'
# 生成文件与样例都不得出现的凭证类字样（子串匹配，不区分大小写）
$script:McpGatewayForbiddenWords = @('token', 'pat', ('pa' + 'ssword'), 'secret', ('api' + 'key'))

<#
.SYNOPSIS
    取某注册表服务对应的 Magpie 服务名；未登记返回 $null。
#>
function Get-McpGatewayName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)

    $key = $Id.ToLowerInvariant()
    if ($script:McpGatewayNames.Contains($key)) { return $script:McpGatewayNames[$key] }
    return $null
}

<#
.SYNOPSIS
    把注册表 StartCommand 的一项按约定换算为本机路径：含分隔符或带脚本扩展名 → 仓库根下的绝对路径；其余原样。
#>
function ConvertTo-McpGatewayLocalItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Item, [switch]$CommandPosition)

    $part = $Item.Trim()
    if (-not $part) { return $part }
    if ([IO.Path]::IsPathRooted($part)) { return $part }
    if (-not $CommandPosition -and $part.StartsWith('-')) { return $part }
    if ($part -match '[/\\]' -or $part -match '\.(py|mjs|cjs|js|ps1|cmd|bat)$') {
        return (Join-Path $Root ($part -replace '/', '\'))
    }
    return $part
}

<#
.SYNOPSIS
    按注册表生成网关路由（[ordered]@{ mcpServers = [ordered]@{ <服务名> = [ordered]@{ command; args; env } } }）。

.DESCRIPTION
    注册表服务没有登记 Magpie 服务名、或启动命令未回填时，抛出中文错误（不生成不完整的结果）。
#>
function New-McpGatewayRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { throw '生成网关路由需要仓库根目录。' }
    $rootPath = $Root.TrimEnd('\', '/')
    $servers = [ordered]@{}
    foreach ($svc in (Get-McpServices)) {
        $name = Get-McpGatewayName -Id $svc.Id
        if (-not $name) {
            throw ('注册表服务 {0} 尚未登记 Magpie 服务名：请在 scripts/lib/gateway-routes.ps1 的 McpGatewayNames 中补充，并同步 gateway.routes.sample.json。' -f $svc.Id)
        }
        # 用注册表原始（仓库相对）StartCommand 按 -Root 重新拼路径；Get-McpServices 的输出已按当前仓库根归一化，不能直接用
        $raw = Get-McpRawStartCommand -Id $svc.Id
        $parts = @()
        if ($null -ne $raw) { $parts = @($raw | ForEach-Object { "$_" }) }
        if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($parts[0]) -or $parts[0] -match '<') {
            throw ('服务 {0}（{1}）的启动命令未回填：请先在 scripts/mcpctl.config.ps1 填写 StartCommand。' -f $name, $svc.Id)
        }
        $command = ConvertTo-McpGatewayLocalItem -Root $rootPath -Item $parts[0] -CommandPosition
        $argList = @()
        if ($parts.Count -gt 1) {
            $argList = @($parts[1..($parts.Count - 1)] | ForEach-Object { ConvertTo-McpGatewayLocalItem -Root $rootPath -Item $_ })
        }
        $servers[$name] = [ordered]@{
            command = $command
            args    = $argList
            env     = [ordered]@{ $script:McpGatewayConfigEnvName = (Join-Path $rootPath $script:McpGatewayConfigFileName) }
        }
    }
    return [ordered]@{ mcpServers = $servers }
}

<#
.SYNOPSIS
    校验一份路由对象是否符合约定；返回中文问题列表，全部合规时为空数组。

.DESCRIPTION
    检查项：顶层只有 mcpServers；服务名集合与注册表一致；条目只含 command / args / env；
    command、args、env 与「按同一仓库根重新生成」的结果逐项一致；序列化文本不含凭证类字样。
#>
function Test-McpGatewayRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Routes, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root)

    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Routes -or $Routes -isnot [System.Collections.IDictionary]) {
        $problems.Add('路由配置的顶层必须是 JSON 对象。')
        return $problems.ToArray()
    }
    $extraTop = @($Routes.Keys | Where-Object { "$_" -ne 'mcpServers' })
    if ($extraTop.Count -gt 0) {
        $problems.Add(('路由配置的顶层只能有 mcpServers 一个键（多出：{0}）。' -f ($extraTop -join '、')))
    }
    $servers = $Routes['mcpServers']
    if ($servers -isnot [System.Collections.IDictionary]) {
        $problems.Add('路由配置缺少 mcpServers 对象。')
        return $problems.ToArray()
    }
    $expected = (New-McpGatewayRoutes -Root $Root)['mcpServers']
    $missing = @($expected.Keys | Where-Object { -not $servers.Contains($_) })
    $unknown = @($servers.Keys | Where-Object { -not $expected.Contains($_) })
    if ($missing.Count -gt 0) { $problems.Add(('路由配置缺少服务：{0}。' -f ($missing -join '、'))) }
    if ($unknown.Count -gt 0) { $problems.Add(('路由配置含未约定的服务名：{0}（服务名固定，不加前缀）。' -f ($unknown -join '、'))) }
    foreach ($name in $expected.Keys) {
        if (-not $servers.Contains($name)) { continue }
        $entry = $servers[$name]
        if ($entry -isnot [System.Collections.IDictionary]) {
            $problems.Add(('{0} 的内容必须是对象。' -f $name))
            continue
        }
        $extra = @($entry.Keys | Where-Object { $_ -notin @('command', 'args', 'env') })
        if ($extra.Count -gt 0) {
            $problems.Add(('{0} 含未约定的键：{1}（只允许 command / args / env）。' -f $name, ($extra -join '、')))
        }
        $want = $expected[$name]
        foreach ($field in @('command', 'args', 'env')) {
            $has = $entry.Contains($field)
            if (-not $has) { $problems.Add(('{0} 缺少 {1}。' -f $name, $field)); continue }
            $actualJson = ConvertTo-McpJsonString -Value $entry[$field]
            $expectedJson = ConvertTo-McpJsonString -Value $want[$field]
            if ($actualJson -ne $expectedJson) {
                $problems.Add(('{0}.{1} 与注册表 StartCommand 不一致：应为 {2}，当前 {3}。' -f $name, $field, $expectedJson, $actualJson))
            }
        }
    }
    $text = ConvertTo-McpJsonString -Value $Routes
    foreach ($word in $script:McpGatewayForbiddenWords) {
        if ($text.ToLowerInvariant().Contains($word)) {
            $problems.Add(('路由配置出现了不应出现的字样“{0}”（网关配置里不得出现凭证类字样）。' -f $word))
        }
    }
    return $problems.ToArray()
}

<#
.SYNOPSIS
    把路由对象序列化为 JSON 文本：UTF-8 无 BOM、2 空格缩进、Windows 路径按 JSON 规则转义（反斜杠写成两个）。
#>
function ConvertTo-McpGatewayRoutesJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Routes)

    return (ConvertTo-McpJsonString -Value $Routes) + "`n"
}

<#
.SYNOPSIS
    把路由对象写入文件（UTF-8 无 BOM）。
#>
function Save-McpGatewayRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Routes, [Parameter(Mandatory = $true)][string]$Path)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-McpGatewayRoutesJson -Routes $Routes
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

<#
.SYNOPSIS
    读取现有路由文件并与注册表比对；返回中文差异列表（文件无法读取时给出原因）。

.OUTPUTS
    System.String[]
#>
function Compare-McpGatewayRoutesFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root)

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $problems.Add(('路由文件不存在：{0}' -f $Path))
        return $problems.ToArray()
    }
    $text = [IO.File]::ReadAllText($Path)
    try {
        $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        # 不回显解析器原文（可能带出文件片段）
        $problems.Add(('路由文件不是合法 JSON：{0}。请重新生成。' -f $Path))
        return $problems.ToArray()
    }
    $routes = ConvertTo-McpOrderedHashtable -InputObject $obj
    foreach ($p in (Test-McpGatewayRoutes -Routes $routes -Root $Root)) { $problems.Add($p) }
    return $problems.ToArray()
}

<#
.SYNOPSIS
    生成可直接粘贴到终端（cmd / PowerShell）执行的 Magpie 登记命令，每条服务一行。

.DESCRIPTION
    命令只覆盖「登记」；分派给哪些 agent 由使用者另行执行 magpie library mcp agents。
#>
function Get-McpGatewayRegisterCommands {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Routes)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Routes['mcpServers'].Keys) {
        $entry = $Routes['mcpServers'][$name]
        $tokens = New-Object System.Collections.Generic.List[string]
        $tokens.Add('magpie')
        $tokens.Add('library')
        $tokens.Add('mcp')
        $tokens.Add('add')
        $tokens.Add($name)
        $tokens.Add('--local')
        $envItem = $Routes['mcpServers'][$name]['env']
        foreach ($k in $envItem.Keys) { $tokens.Add(('"env={0}={1}"' -f $k, $envItem[$k])) }
        $tokens.Add('--')
        $tokens.Add(('"{0}"' -f $entry['command']))
        foreach ($a in @($entry['args'])) { $tokens.Add(('"{0}"' -f $a)) }
        $lines.Add(($tokens -join ' '))
    }
    return $lines.ToArray()
}
