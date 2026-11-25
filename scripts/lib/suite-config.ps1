#Requires -Version 5.1
<#
.SYNOPSIS
    统一配置 mcp.config.json 的读写模块（T-CFG-02）。

.DESCRIPTION
    四个服务的连接信息与凭证集中保存在仓库根的 mcp.config.json（真实文件已被
    .gitignore 排除，仓库只分发模板 mcp.config.sample.json）。本模块是总控读写该文件的
    【唯一入口】：注册表、向导、诊断、导出一律通过这里取数，不得各自解析文件。

    约定：
      1. 兼容 Windows PowerShell 5.1：不使用 ConvertFrom-Json -AsHashtable，
         读取结果统一转换为 [ordered]@{}（保持文件中的键顺序）。
      2. 写入格式固定：UTF-8 无 BOM、2 空格缩进；顶层键顺序 configVersion → _comment →
         services → _hints，services 内各段顺序与注册表一致，段内保持文件原有字段顺序。
      3. 原子写入：先写同目录临时文件，再替换目标文件；任何一步失败都不留下半截文件，
         原文件保持不变。
      4. 错误信息全部为中文，且【绝不包含字段值】（文件中有凭证）。
      5. _comment 与 _hints 是给人看的说明，程序逻辑必须忽略它们，缺失不影响读写。

    字段含义见 docs/services/配置字段说明.md；结构契约见 mcp.config.schema.json。

.NOTES
    分工：JSON Schema 只管结构（键名、类型、枚举）；“必填项是否已填写、是否仍是
    <...> 占位符”属于就绪判定，由本模块的 Test-McpSuiteConfigReady 负责。
#>

# 加载注册表（服务清单：ConfigKey 即统一配置中的段名）
. (Join-Path -Path $PSScriptRoot -ChildPath 'registry.ps1')

# 占位符形态：<...>（模板参考值中尚未替换的项），就绪判定视为“未填写”
$script:McpSuitePlaceholderPattern = '^\s*<.*>\s*$'

# 统一配置模板文件名（位于仓库根；仓库内唯一随仓库分发的配置文件）
$script:McpSuiteSampleFileName = 'mcp.config.sample.json'

# 就绪判定用到的必填字段（见 docs/services/配置字段说明.md 第 3 节）
# atlassian.email 为条件必填：deployment=cloud 时参与就绪判定，server 时可留空
$script:McpSuiteRequiredFields = @{
    gerrit    = @('baseUrl', 'username', 'httpPassword')
    github    = @('baseUrl', 'pat')
    jenkins   = @('baseUrl', 'username', 'apiToken')
    atlassian = @('deployment', 'jiraBaseUrl', 'confluenceBaseUrl', 'personalAccessToken')
}
$script:McpSuiteDeployments = @('cloud', 'server')

# ---------------------------------------------------------------------------
# 路径与段名
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    获取统一配置文件路径（绝对路径）。
#>
function Get-McpSuiteConfigPath {
    $p = "$($script:McpCtlGlobal.SuiteConfigPath)"
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path (Get-McpRepoRoot) $p)
}

<#
.SYNOPSIS
    获取统一配置模板路径（仓库根的 mcp.config.sample.json）。
#>
function Get-McpSuiteConfigSamplePath {
    return (Join-Path (Get-McpRepoRoot) $script:McpSuiteSampleFileName)
}

<#
.SYNOPSIS
    获取全部配置段名（小写）。顺序即注册表顺序，也是写入文件时 services 各段的固定顺序。
#>
function Get-McpSuiteServiceKeys {
    $keys = @(Get-McpServices | ForEach-Object { "$($_.ConfigKey)".Trim().ToLowerInvariant() } | Where-Object { $_ })
    return ,$keys
}

<#
.SYNOPSIS
    把用户输入的段名归一为注册表中的 ConfigKey（不区分大小写）；未知段名返回 $null。
#>
function Resolve-McpSuiteConfigKey {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Key)

    $wanted = "$Key".Trim().ToLowerInvariant()
    foreach ($k in (Get-McpSuiteServiceKeys)) {
        if ($k -eq $wanted) { return $k }
    }
    return $null
}

# ---------------------------------------------------------------------------
# JSON 转换（5.1 兼容：不用 -AsHashtable，自写序列化保证固定格式）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    把 ConvertFrom-Json 的结果（PSCustomObject）转换为 [ordered]@{}，保持键顺序；数组保持为数组。
#>
function ConvertTo-McpOrderedHashtable {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $table["$k"] = ConvertTo-McpOrderedHashtable -InputObject $InputObject[$k] }
        return $table
    }
    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($p.MemberType -ne 'NoteProperty') { continue }
            $table[$p.Name] = ConvertTo-McpOrderedHashtable -InputObject $p.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($e in $InputObject) { [void]$items.Add((ConvertTo-McpOrderedHashtable -InputObject $e)) }
        return ,$items.ToArray()
    }
    return $InputObject
}

function ConvertTo-McpJsonStringLiteral {
    param([AllowEmptyString()][string]$Text)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -lt 0x20) { [void]$sb.Append('\u{0:x4}' -f $code) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

<#
.SYNOPSIS
    把 [ordered]@{} / 哈希表 / 数组 / 标量序列化为 JSON 文本：2 空格缩进、保持键顺序、中文原样输出。
#>
function ConvertTo-McpJsonString {
    [CmdletBinding()]
    param([AllowNull()]$Value, [int]$Depth = 0)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-McpJsonStringLiteral -Text $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
    if ($Value -is [datetime]) { return (ConvertTo-McpJsonStringLiteral -Text $Value.ToString('o')) }
    if ($Value -is [System.Collections.IDictionary]) {
        $indent = '  ' * $Depth
        $child = '  ' * ($Depth + 1)
        $lines = New-Object System.Collections.ArrayList
        foreach ($k in $Value.Keys) {
            $item = ConvertTo-McpJsonString -Value $Value[$k] -Depth ($Depth + 1)
            [void]$lines.Add(('{0}{1}: {2}' -f $child, (ConvertTo-McpJsonStringLiteral -Text "$k"), $item))
        }
        if ($lines.Count -eq 0) { return '{}' }
        return "{`n" + ($lines -join ",`n") + "`n" + $indent + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $indent = '  ' * $Depth
        $child = '  ' * ($Depth + 1)
        $lines = New-Object System.Collections.ArrayList
        foreach ($e in $Value) {
            $item = ConvertTo-McpJsonString -Value $e -Depth ($Depth + 1)
            [void]$lines.Add($child + $item)
        }
        if ($lines.Count -eq 0) { return '[]' }
        return "[`n" + ($lines -join ",`n") + "`n" + $indent + "]"
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] `
        -or $Value -is [long] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        $culture = [Globalization.CultureInfo]::InvariantCulture
        if ($Value -is [double] -or $Value -is [single]) {
            if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { throw '统一配置中出现无法写入 JSON 的数值（NaN / Infinity）' }
        }
        return ($Value.ToString($null, $culture))
    }
    if ($Value -is [char]) { return (ConvertTo-McpJsonStringLiteral -Text "$Value") }
    throw ('统一配置中出现了不支持的字段值类型：{0}' -f $Value.GetType().Name)
}

<#
.SYNOPSIS
    把统一配置文本解析为 [ordered]@{} 并做结构校验；任何问题都抛出中文错误，且不回显解析器原始信息。
#>
function ConvertFrom-McpSuiteConfigText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw "统一配置文件内容为空：$Path" }
    try {
        $obj = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    }
    catch {
        # 解析器原始报错可能带出文件片段（含凭证），这里只提取行列号
        $where = ''
        if ($_.Exception.Message -match 'line (\d+), position (\d+)') { $where = '（第 {0} 行，第 {1} 列附近）' -f $Matches[1], $Matches[2] }
        throw "统一配置文件不是合法 JSON：$Path$where。请检查引号、逗号与括号是否成对。"
    }
    if ($null -eq $obj -or $obj -is [System.Array]) { throw "统一配置的顶层必须是 JSON 对象：$Path" }
    $cfg = ConvertTo-McpOrderedHashtable -InputObject $obj
    if ($cfg -isnot [System.Collections.IDictionary]) { throw "统一配置的顶层必须是 JSON 对象：$Path" }
    if (-not $cfg.Contains('configVersion') -or "$($cfg['configVersion'])" -ne '1') {
        throw "统一配置的 configVersion 不受支持：$Path（当前仅支持 1）"
    }
    if (-not $cfg.Contains('services') -or $cfg['services'] -isnot [System.Collections.IDictionary]) {
        throw "统一配置缺少 services 配置段，或该段不是对象：$Path"
    }
    return $cfg
}

# ---------------------------------------------------------------------------
# 读取
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    读取统一配置全文，返回 [ordered]@{}（顶层键顺序与文件一致）。

.DESCRIPTION
    文件不存在、不是合法 JSON、顶层不是对象、configVersion 不是 1、缺少 services 时抛出中文错误。
#>
function Get-McpSuiteConfig {
    [CmdletBinding()]
    param()

    $path = Get-McpSuiteConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ("统一配置文件不存在：{0}。请先把模板 mcp.config.sample.json 复制为该文件并填写（字段说明见 docs/services/配置字段说明.md）。" -f $path)
    }
    try {
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    }
    catch {
        throw ("统一配置文件读取失败：{0}（{1}）" -f $path, $_.Exception.Message)
    }
    return (ConvertFrom-McpSuiteConfigText -Text $text -Path $path)
}

<#
.SYNOPSIS
    读取统一配置中某个服务的配置段（[ordered]@{}）。

.PARAMETER Key
    配置段名（注册表 ConfigKey，如 gerrit），不区分大小写。

.PARAMETER AllowMissing
    配置段不存在时返回 $null，而不是报错。
#>
function Get-McpSuiteConfigSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Key,
        [switch]$AllowMissing
    )

    $canon = Resolve-McpSuiteConfigKey -Key $Key
    if (-not $canon) {
        throw ('未知的配置段：{0}（可用：{1}）' -f $Key, ((Get-McpSuiteServiceKeys) -join ' / '))
    }
    $services = (Get-McpSuiteConfig)['services']
    if (-not $services.Contains($canon)) {
        if ($AllowMissing) { return $null }
        throw "统一配置缺少 services.$canon 配置段：请对照模板 mcp.config.sample.json 补全"
    }
    $section = $services[$canon]
    if ($section -isnot [System.Collections.IDictionary]) {
        throw "统一配置的 services.$canon 必须是 JSON 对象"
    }
    return $section
}

# ---------------------------------------------------------------------------
# 写入（原子）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    原子写入统一配置：先写同目录临时文件，再替换目标文件。
#>
function Write-McpSuiteConfigAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $tmp = Join-Path $dir ('.' + $leaf + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            throw (New-Object System.IO.DirectoryNotFoundException "目录不存在：$dir")
        }
        $bytes = $utf8.GetBytes($Text)
        $stream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($Path)) {
            # 同卷原子替换（第三个参数传真正的 null：不生成备份文件）；目标被其他进程占用等情况会抛 IO 异常，原文件保持不变
            [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmp, $Path)
        }
    }
    catch {
        $reason = $_.Exception.Message
        if ($_.Exception -is [System.UnauthorizedAccessException]) { $reason = '没有写入权限' }
        throw ("统一配置写入失败：{0}（{1}）。原文件未改动。" -f $Path, $reason)
    }
    finally {
        if ([IO.File]::Exists($tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-McpSuiteSampleSection {
    # 读取模板中某服务的配置段；模板缺失或不可解析时返回 $null（不抛错，模板只用于参考）
    param([string]$Key)

    $samplePath = Get-McpSuiteConfigSamplePath
    if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) { return $null }
    try {
        $cfg = ConvertFrom-McpSuiteConfigText -Text ([IO.File]::ReadAllText($samplePath, [Text.Encoding]::UTF8)) -Path $samplePath
    }
    catch {
        return $null
    }
    $services = $cfg['services']
    if (-not $services.Contains($Key) -or $services[$Key] -isnot [System.Collections.IDictionary]) { return $null }
    return $services[$Key]
}

function Find-McpSuiteSectionKey {
    # 在配置段中按不区分大小写查找字段名，返回段内的原始键名；找不到返回 $null
    param($Section, [AllowEmptyString()][string]$Name)
    if ($null -eq $Section) { return $null }
    foreach ($k in $Section.Keys) {
        if ("$k" -eq $Name) { return "$k" }
    }
    return $null
}

function ConvertTo-McpSuiteFieldValue {
    # 按模板中的字段类型规整待写入的值：数组字段传入单个字符串时包成数组，空值写成空数组。
    param($Value, $SampleValue)

    $isArray = ($SampleValue -is [System.Array])
    if (-not $isArray) { return ,$Value }
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return ,@() }
    if ($Value -is [string]) { return ,@($Value) }
    if ($Value -is [System.Collections.IDictionary]) { throw '数组字段不能写入对象' }
    if ($Value -is [System.Collections.IEnumerable]) { return ,@($Value) }
    return ,@($Value)
}

<#
.SYNOPSIS
    更新统一配置中某个服务的若干字段（其他字段、其他服务段、_comment 与 _hints 原样保留）。

.DESCRIPTION
    - 只改 $Values 中给出的字段；字段名必须是模板或该段现有的字段，防止拼错。
    - 段内保持文件原有字段顺序，新字段追加在末尾。
    - 写入前把生成的文本重新解析自检；写入采用原子替换，失败时原文件不变。
    - 返回实际写入的字段名列表（不含值）。

.PARAMETER Key
    配置段名（注册表 ConfigKey，如 gerrit），不区分大小写。

.PARAMETER Values
    要写入的字段（哈希表：字段名 → 值）。

.PARAMETER Create
    配置段不存在时新建该段（默认报错）。
#>
function Set-McpSuiteConfigSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values,
        [switch]$Create
    )

    $canon = Resolve-McpSuiteConfigKey -Key $Key
    if (-not $canon) {
        throw ('未知的配置段：{0}（可用：{1}）' -f $Key, ((Get-McpSuiteServiceKeys) -join ' / '))
    }
    $path = Get-McpSuiteConfigPath
    $cfg = Get-McpSuiteConfig
    $services = $cfg['services']

    # 现有段（保持原有字段顺序）
    $existing = [ordered]@{}
    if ($services.Contains($canon)) {
        if ($services[$canon] -isnot [System.Collections.IDictionary]) { throw "统一配置的 services.$canon 必须是 JSON 对象，无法写入" }
        foreach ($k in $services[$canon].Keys) { $existing["$k"] = $services[$canon][$k] }
    }
    elseif (-not $Create) {
        throw "统一配置缺少 services.$canon 配置段；如需新建请使用 -Create"
    }

    # 允许的字段名：该段现有字段 ∪ 模板中的字段（防止拼错字段名）
    $allowed = New-Object System.Collections.ArrayList
    foreach ($k in $existing.Keys) { [void]$allowed.Add("$k") }
    $sampleSection = Get-McpSuiteSampleSection -Key $canon
    if ($null -ne $sampleSection) {
        foreach ($k in $sampleSection.Keys) { if (-not $allowed.Contains("$k")) { [void]$allowed.Add("$k") } }
    }
    foreach ($k in $Values.Keys) {
        $name = "$k"
        if ($allowed -notcontains $name) {
            throw ('未知字段：services.{0}.{1}（可用字段：{2}）' -f $canon, $name, ($allowed -join ' / '))
        }
    }

    # 合并：已有键按现有键名落位（保持原大小写），新键追加
    $merged = [ordered]@{}
    foreach ($k in $existing.Keys) {
        $matched = $null
        foreach ($vk in $Values.Keys) { if ("$vk" -eq "$k") { $matched = $vk } }
        if ($null -ne $matched) {
            $sampleKey = Find-McpSuiteSectionKey -Section $sampleSection -Name "$k"
            # 注意：用赋值而不是 if 表达式取值——空数组经管道输出会丢失
            $sampleValue = $null
            if ($sampleKey) { $sampleValue = $sampleSection[$sampleKey] }
            $merged[$k] = ConvertTo-McpSuiteFieldValue -Value $Values[$matched] -SampleValue $sampleValue
        }
        else {
            $merged[$k] = $existing[$k]
        }
    }
    foreach ($vk in $Values.Keys) {
        $name = "$vk"
        if ($merged.Contains($name)) { continue }
        $sampleValue = $null
        $sampleKey = Find-McpSuiteSectionKey -Section $sampleSection -Name $name
        if ($sampleKey) {
            # 新字段采用模板中的字段名写法（统一大小写），并按模板类型规整取值
            $name = $sampleKey
            $sampleValue = $sampleSection[$sampleKey]
        }
        $merged[$name] = ConvertTo-McpSuiteFieldValue -Value $Values[$vk] -SampleValue $sampleValue
    }

    # 组装 services：各段按注册表顺序排列，其余未知段按原顺序排在后面
    $newServices = [ordered]@{}
    foreach ($sk in (Get-McpSuiteServiceKeys)) {
        if ($sk -eq $canon) { $newServices[$sk] = $merged }
        elseif ($services.Contains($sk)) { $newServices[$sk] = $services[$sk] }
    }
    foreach ($sk in $services.Keys) {
        if (-not $newServices.Contains("$sk")) { $newServices["$sk"] = $services[$sk] }
    }

    # 组装顶层：configVersion → _comment → services → _hints，其余键按原顺序排在后面
    $newCfg = [ordered]@{}
    $newCfg['configVersion'] = $cfg['configVersion']
    foreach ($topName in @('_comment', 'services', '_hints')) {
        if ($topName -eq 'services') { $newCfg['services'] = $newServices; continue }
        if ($cfg.Contains($topName)) { $newCfg[$topName] = $cfg[$topName] }
    }
    foreach ($tk in $cfg.Keys) {
        if (-not $newCfg.Contains("$tk")) { $newCfg["$tk"] = $cfg[$tk] }
    }

    $text = (ConvertTo-McpJsonString -Value $newCfg) + "`n"
    try {
        $null = ConvertFrom-McpSuiteConfigText -Text $text -Path '（待写入的内容）'
    }
    catch {
        throw ('生成的统一配置文本未通过自检，已中止写入（原文件未改动）：{0}' -f $_.Exception.Message)
    }
    Write-McpSuiteConfigAtomic -Path $path -Text $text

    $written = @($Values.Keys | ForEach-Object { "$_" })
    return ,$written
}

# ---------------------------------------------------------------------------
# 就绪判定 / 初始化 / 提示
# ---------------------------------------------------------------------------

function Test-McpSuiteValueFilled {
    # 值已填写：非空，且不是 <...> 占位符
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return $true }
    $s = "$Value"
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -notmatch $script:McpSuitePlaceholderPattern)
}

<#
.SYNOPSIS
    判定统一配置的就绪状态（不抛错；问题通过 Reason 字段说明）。

.DESCRIPTION
    就绪 = 配置文件存在且可解析、该服务段存在、enabled=true、启用条件下的必填字段均已填写
    （空值与 <...> 占位符都算未填写）。enabled=false 的服务记为“已禁用”，必填项可留空。

.PARAMETER Key
    配置段名（注册表 ConfigKey）；省略时返回全部服务。

.OUTPUTS
    每个服务一个对象：Code / Id / DisplayName / Key / FileExists / FileValid / SectionExists /
    Enabled / Ready / State（已就绪 | 已禁用 | 未就绪）/ Missing（未填写的字段路径，如
    services.gerrit.baseUrl）/ Reason（未就绪的中文原因）
#>
function Test-McpSuiteConfigReady {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Key)

    $services = Get-McpServices
    if ($Key) {
        $canon = Resolve-McpSuiteConfigKey -Key $Key
        if (-not $canon) {
            throw ('未知的配置段：{0}（可用：{1}）' -f $Key, ((Get-McpSuiteServiceKeys) -join ' / '))
        }
        $services = $services | Where-Object { "$($_.ConfigKey)".ToLowerInvariant() -eq $canon }
    }

    # 统一配置文件只读一次，四个服务共用
    $path = Get-McpSuiteConfigPath
    $fileExists = Test-Path -LiteralPath $path -PathType Leaf
    $cfg = $null
    $fileError = ''
    if ($fileExists) {
        try { $cfg = Get-McpSuiteConfig }
        catch { $fileError = $_.Exception.Message }
    }

    foreach ($svc in $services) {
        $canon = "$($svc.ConfigKey)".ToLowerInvariant()
        $r = [ordered]@{
            Code          = $svc.Code
            Id            = $svc.Id
            DisplayName   = $svc.DisplayName
            Key           = $canon
            FileExists    = $fileExists
            FileValid     = ($null -ne $cfg)
            SectionExists = $false
            Enabled       = $false
            Ready         = $false
            Missing       = @()
            Reason        = ''
            State         = '未就绪'
        }
        if (-not $fileExists) {
            $r.Reason = '统一配置文件不存在'
        }
        elseif ($null -eq $cfg) {
            $r.Reason = '统一配置文件无法解析：' + $fileError
        }
        else {
            $svcCfg = $cfg['services']
            if ($svcCfg.Contains($canon) -and $svcCfg[$canon] -is [System.Collections.IDictionary]) {
                $r.SectionExists = $true
                $section = $svcCfg[$canon]
                $enabledValue = if ($section.Contains('enabled')) { $section['enabled'] } else { $null }
                if ($enabledValue -isnot [bool]) {
                    $r.Reason = 'enabled 必须是布尔值 true / false'
                }
                elseif (-not $enabledValue) {
                    $r.Enabled = $false
                    $r.State = '已禁用'
                    $r.Reason = '已在统一配置中禁用（enabled=false）'
                }
                else {
                    $r.Enabled = $true
                    $missing = @()
                    $required = @($script:McpSuiteRequiredFields[$canon])
                    $badDeployment = $false
                    if ($canon -eq 'atlassian') {
                        $deployment = if ($section.Contains('deployment')) { "$($section['deployment'])".Trim().ToLowerInvariant() } else { '' }
                        if ($deployment -eq 'cloud') { $required += 'email' }
                        if ((Test-McpSuiteValueFilled -Value $deployment) -and ($script:McpSuiteDeployments -notcontains $deployment)) {
                            $badDeployment = $true
                            $missing += 'services.atlassian.deployment'
                        }
                    }
                    foreach ($f in $required) {
                        $v = if ($section.Contains($f)) { $section[$f] } else { $null }
                        if (-not (Test-McpSuiteValueFilled -Value $v)) { $missing += "services.$canon.$f" }
                    }
                    $r.Missing = $missing
                    if ($missing.Count -eq 0) {
                        $r.Ready = $true
                        $r.State = '已就绪'
                    }
                    elseif ($badDeployment) {
                        $r.Reason = 'deployment 只能是 cloud 或 server'
                    }
                    else {
                        $r.Reason = '必填项未填写或仍为占位符'
                    }
                }
            }
            else {
                $r.Reason = "统一配置缺少 services.$canon 配置段"
            }
        }
        [pscustomobject]$r
    }
}

<#
.SYNOPSIS
    用模板 mcp.config.sample.json 生成统一配置文件 mcp.config.json（原子写入）。

.PARAMETER Force
    目标文件已存在时仍然覆盖（会丢失现有配置，调用方须先确认）。
#>
function Initialize-McpSuiteConfigFromSample {
    [CmdletBinding()]
    param([switch]$Force)

    $path = Get-McpSuiteConfigPath
    $samplePath = Get-McpSuiteConfigSamplePath
    if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) {
        throw "统一配置模板不存在：$samplePath"
    }
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "统一配置已存在：$path（如需用模板覆盖请加 -Force，覆盖会丢失现有配置）"
    }
    $text = [IO.File]::ReadAllText($samplePath, [Text.Encoding]::UTF8)
    $null = ConvertFrom-McpSuiteConfigText -Text $text -Path $samplePath
    Write-McpSuiteConfigAtomic -Path $path -Text $text
    return $path
}

<#
.SYNOPSIS
    获取字段提示（来自统一配置的 _hints；本地文件没有时回退到模板）。

.PARAMETER Key
    配置段名（注册表 ConfigKey）；给出时只返回该段的提示，并去掉“段名.”前缀。

.OUTPUTS
    [ordered]@{}：字段路径（或去掉前缀后的字段名）→ 中文提示
#>
function Get-McpSuiteConfigHints {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Key)

    $canon = $null
    if ($Key) {
        $canon = Resolve-McpSuiteConfigKey -Key $Key
        if (-not $canon) {
            throw ('未知的配置段：{0}（可用：{1}）' -f $Key, ((Get-McpSuiteServiceKeys) -join ' / '))
        }
    }

    $hints = $null
    $path = Get-McpSuiteConfigPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $cfg = Get-McpSuiteConfig
            if ($cfg.Contains('_hints') -and $cfg['_hints'] -is [System.Collections.IDictionary]) { $hints = $cfg['_hints'] }
        }
        catch {
            # 本地文件有问题时不在这里报错（就绪判定会报），提示回退到模板
            $hints = $null
        }
    }
    if ($null -eq $hints) {
        $samplePath = Get-McpSuiteConfigSamplePath
        if (Test-Path -LiteralPath $samplePath -PathType Leaf) {
            try {
                $sampleCfg = ConvertFrom-McpSuiteConfigText -Text ([IO.File]::ReadAllText($samplePath, [Text.Encoding]::UTF8)) -Path $samplePath
                if ($sampleCfg.Contains('_hints') -and $sampleCfg['_hints'] -is [System.Collections.IDictionary]) { $hints = $sampleCfg['_hints'] }
            }
            catch {
                $hints = $null
            }
        }
    }

    $result = [ordered]@{}
    if ($null -eq $hints) { return $result }
    # _hints 的键是完整字段路径（services.<段名>.<字段名>）；按段查询时去掉前缀，只留字段名
    $prefix = 'services.' + $canon + '.'
    foreach ($k in $hints.Keys) {
        $name = "$k"
        $value = "$($hints[$k])"
        if ($canon) {
            if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $result[$name.Substring($prefix.Length)] = $value }
        }
        else {
            $result[$name] = $value
        }
    }
    return $result
}
