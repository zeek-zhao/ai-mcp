#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 配置向导（单文件逐字段录入）、从旧配置导入与连通性测试。

.DESCRIPTION
    统一配置改造（T-CFG-04）后的配置入口，只读写一个文件：仓库根的 mcp.config.json。
      - 首次进入：统一配置文件不存在时提示“将从 sample 生成”，调用 Initialize-McpSuiteConfigFromSample；
        文件无法解析时不覆盖，提示手工修复。
      - 旧版文件清理：本地文件若带旧版遗留的 _hints 段，进入向导时调用 Remove-McpSuiteLegacyHints
        原地清除（其余配置内容不变）；字段提示一律取自模板。
      - 逐字段录入：每个字段先打印中文说明（_hints）、参考值（模板）与当前状态，再读入新值；
        每录入一个字段即原子写回（Set-McpSuiteConfigSection），中途中断文件仍可解析；
        敏感字段只显示“已设置 / 未设置”，不回显值。
      - 就绪判定：Test-McpSuiteConfigReady，缺失字段以中文名输出。
      - 从旧配置导入：识别各服务目录下的 *_config.json 与 mcp-github/.env，逐项询问覆盖 / 保留后
        写入统一配置；旧文件不自动删除；不打印凭证。
      - 连通性测试：Gerrit 已实装，其余服务以握手探活为准。
    统一配置的读写一律经 scripts/lib/suite-config.ps1，本文件不直接解析统一配置文件。

    安全约束：任何控制台输出与日志都不得出现明文凭证；连通测试的报错不复述凭证。

.EXAMPLE
    . (Join-Path $PSScriptRoot 'lib\config-wizard.ps1')
    Invoke-McpConfigWizard
    Invoke-McpLegacyConfigImport
    Invoke-McpConnectivityTest -Code A
#>

# 加载统一配置模块（内部已加载注册表）
. (Join-Path -Path $PSScriptRoot -ChildPath 'suite-config.ps1')

# 输入流已关闭（Read-Host 读不到输入）时置为 $true：各交互循环据此退出，避免在非交互环境下空转
$script:McpInputClosed = $false

# ---------------------------------------------------------------------------
# 输入助手（全部交互读取集中于此，便于测试时覆写）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    读取单行输入；直接回车时返回 $Default。
#>
function Read-McpInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowEmptyString()][string]$Default = ''
    )
    $v = Read-Host -Prompt $Prompt
    if ($null -eq $v) { $script:McpInputClosed = $true; return '' }
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

<#
.SYNOPSIS
    读取敏感输入（隐藏不回显）；直接回车返回 $null（表示“保留现有值”）。
#>
function Read-McpSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Prompt)
    if ([Console]::IsInputRedirected) {
        # 标准输入被重定向（管道 / 脚本驱动）时 Read-Host -AsSecureString 无法工作且会一直等待：直接拒绝，凭证只能在交互式终端输入
        throw '无法隐藏读取敏感字段：标准输入不是交互式终端。请在终端中直接运行 mcpctl 并手动输入凭证，或直接编辑 mcp.config.json。'
    }
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        if ([string]::IsNullOrEmpty($plain)) { return $null }
        return $plain
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

<#
.SYNOPSIS
    读取“是/否”确认；直接回车视为否。
#>
function Read-McpYesNo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $v = Read-Host -Prompt "$Prompt [y/N]"
    if ($null -eq $v) { $script:McpInputClosed = $true; return $false }
    return ($v -match '^(y|Y|是)$')
}

# ---------------------------------------------------------------------------
# 字段目录：决定录入顺序、中文名、输入方式与是否敏感
#   字段集合与顺序必须和模板 mcp.config.sample.json 的 services 段一致（进入向导时自检）。
#   Kind：bool 开关 | choice 枚举 | url 地址 | text 文本 | secret 敏感输入 | list 逗号分隔的列表
#         | reserved 预留字段（只展示说明，不录入）
# ---------------------------------------------------------------------------

function New-McpSuiteField {
    # 生成字段目录条目
    param(
        [string]$Name, [string]$Label, [string]$Kind, [bool]$Required,
        [string[]]$Choices = @(), [string]$RequiredWhenDeployment = ''
    )
    [ordered]@{
        Name                  = $Name
        Label                 = $Label
        Kind                  = $Kind
        Required              = $Required
        Choices               = @($Choices)
        RequiredWhenDeployment = $RequiredWhenDeployment
    }
}

$script:McpSuiteFieldCatalog = [ordered]@{
    gerrit    = @(
        (New-McpSuiteField -Name 'enabled' -Label '是否启用 Gerrit' -Kind 'bool' -Required $true)
        (New-McpSuiteField -Name 'baseUrl' -Label 'Gerrit 实例地址' -Kind 'url' -Required $true)
        (New-McpSuiteField -Name 'instanceName' -Label '显示名称' -Kind 'text' -Required $false)
        (New-McpSuiteField -Name 'username' -Label 'Gerrit 用户名' -Kind 'text' -Required $true)
        (New-McpSuiteField -Name 'httpPassword' -Label 'HTTP 凭证（HTTP 密码）' -Kind 'secret' -Required $true)
        (New-McpSuiteField -Name 'instances' -Label '多实例列表' -Kind 'reserved' -Required $false)
    )
    github    = @(
        (New-McpSuiteField -Name 'enabled' -Label '是否启用 GitHub' -Kind 'bool' -Required $true)
        (New-McpSuiteField -Name 'baseUrl' -Label 'GitHub 地址（GitHub Enterprise 填 API 地址）' -Kind 'url' -Required $true)
        (New-McpSuiteField -Name 'pat' -Label '个人访问令牌（PAT）' -Kind 'secret' -Required $true)
        (New-McpSuiteField -Name 'scope' -Label '范围限定（owner/repo 或组织名）' -Kind 'text' -Required $false)
    )
    jenkins   = @(
        (New-McpSuiteField -Name 'enabled' -Label '是否启用 Jenkins' -Kind 'bool' -Required $true)
        (New-McpSuiteField -Name 'baseUrl' -Label 'Jenkins 地址' -Kind 'url' -Required $true)
        (New-McpSuiteField -Name 'username' -Label 'Jenkins 用户名' -Kind 'text' -Required $true)
        (New-McpSuiteField -Name 'apiToken' -Label 'API Token' -Kind 'secret' -Required $true)
        (New-McpSuiteField -Name 'readOnly' -Label '只读开关（提示性，不会被强制拦截）' -Kind 'bool' -Required $false)
        (New-McpSuiteField -Name 'instances' -Label '多实例列表' -Kind 'reserved' -Required $false)
    )
    atlassian = @(
        (New-McpSuiteField -Name 'enabled' -Label '是否启用 Atlassian（Jira + Confluence）' -Kind 'bool' -Required $true)
        (New-McpSuiteField -Name 'deployment' -Label '部署类型（cloud / server）' -Kind 'choice' -Required $true -Choices @('cloud', 'server'))
        (New-McpSuiteField -Name 'jiraBaseUrl' -Label 'Jira 地址' -Kind 'url' -Required $true)
        (New-McpSuiteField -Name 'confluenceBaseUrl' -Label 'Confluence 地址' -Kind 'url' -Required $true)
        (New-McpSuiteField -Name 'email' -Label '登录邮箱' -Kind 'text' -Required $false -RequiredWhenDeployment 'cloud')
        (New-McpSuiteField -Name 'personalAccessToken' -Label '访问令牌（Cloud 填 API Token，Server 填 PAT）' -Kind 'secret' -Required $true)
        (New-McpSuiteField -Name 'projectScope' -Label 'Jira 项目范围' -Kind 'list' -Required $false)
        (New-McpSuiteField -Name 'spaceScope' -Label 'Confluence 空间范围' -Kind 'list' -Required $false)
    )
}

<#
.SYNOPSIS
    获取某服务在向导中的字段目录（已自检：字段集合与模板一致）。

.OUTPUTS
    字段条目数组（Name / Label / Kind / Required / Choices / RequiredWhenDeployment）。
#>
function Get-McpSuiteFieldCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Key)

    $canon = Resolve-McpSuiteConfigKey -Key $Key
    if (-not $canon) {
        throw ('未知的配置段：{0}（可用：{1}）' -f $Key, ((Get-McpSuiteServiceKeys) -join ' / '))
    }
    if (-not $script:McpSuiteFieldCatalog.Contains($canon)) {
        throw ('配置向导没有 services.{0} 的字段目录' -f $canon)
    }

    # 自检：字段目录与模板的字段集合必须一致，否则录入界面会与文件脱节
    $reference = Get-McpSuiteConfigReference -Key $canon
    if ($reference.Count -eq 0) {
        throw ('无法读取统一配置模板中 services.{0} 的参考值：{1}' -f $canon, (Get-McpSuiteConfigSamplePath))
    }
    $catalogNames = @($script:McpSuiteFieldCatalog[$canon] | ForEach-Object { $_.Name })
    $referenceNames = @($reference.Keys | ForEach-Object { "$_" })
    $diff = @(Compare-Object -ReferenceObject $referenceNames -DifferenceObject $catalogNames)
    if ($diff.Count -gt 0) {
        throw ('配置向导的字段目录与模板不一致（services.{0}）：{1}' -f $canon, (($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '；'))
    }
    return ,@($script:McpSuiteFieldCatalog[$canon])
}

<#
.SYNOPSIS
    按字段路径（services.<段>.<字段>）取字段的中文名；找不到时原样返回路径。
#>
function Get-McpSuiteFieldLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    $parts = "$Path".Split('.')
    if ($parts.Count -eq 3 -and $script:McpSuiteFieldCatalog.Contains($parts[1])) {
        foreach ($f in $script:McpSuiteFieldCatalog[$parts[1]]) {
            if ($f.Name -eq $parts[2]) { return $f.Label }
        }
    }
    return "$Path"
}

function Get-McpSuiteReadyIssueLines {
    <#
    .SYNOPSIS
        把就绪判定结果里的逐字段问题转成展示行：“中文名（字段路径）：问题说明”，不含字段值。
    .OUTPUTS
        字符串数组；判定结果没有逐字段问题（如配置段缺失、文件无法解析）时返回空数组。
    #>
    param([Parameter(Mandatory = $true)]$Ready)

    $lines = @()
    $missing = @($Ready.Missing)
    $kinds = @($Ready.MissingKind)
    $texts = @($Ready.IssueText)
    for ($i = 0; $i -lt $missing.Count; $i++) {
        $text = if ($i -lt $texts.Count) { "$($texts[$i])" } else { '未填写，请填写' }
        $lines += ('{0}（{1}）：{2}' -f (Get-McpSuiteFieldLabel -Path $missing[$i]), $missing[$i], $text)
    }
    return ,$lines
}

function Format-McpSuiteValue {
    # 控制台展示用的取值格式（数组按 JSON 列表形式展示）
    param($Value)

    if ($null -eq $Value) { return '（空）' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { if ($_ -is [string]) { '"' + $_ + '"' } else { "$_" } })
        if ($items.Count -eq 0) { return '[]' }
        return '[' + ($items -join ', ') + ']'
    }
    $s = "$Value"
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    return $s
}

function Get-McpSuiteFieldStatusText {
    # 字段的当前状态：已设置 / 未设置 / 可留空；敏感字段只显示已设置 / 未设置
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Field,
        $Value,
        [bool]$ServiceEnabled,
        [string]$Deployment
    )

    if ("$($Field.Kind)" -eq 'reserved') { return '预留字段（当前版本不录入，保持留空）' }
    # 未填写的原因种类：placeholder 占位符 / template 模板参考值 / empty 空值；$null 或空串表示已填写
    $issue = Get-McpSuiteValueIssue -Value $Value
    $filled = [string]::IsNullOrEmpty("$issue")
    $sensitive = ("$($Field.Kind)" -eq 'secret')
    if ($filled) {
        if ($sensitive) { return '已设置' }
        return ('已设置（当前值：{0}）' -f (Format-McpSuiteValue -Value $Value))
    }

    # 未设置：统一以“未设置”开头并说明是否必填；敏感字段同样不出现任何值
    $required = [bool]$Field.Required
    $when = "$($Field.RequiredWhenDeployment)"
    if ($when -and $Deployment -eq $when) { $required = $true }
    if ("$issue" -eq 'template') {
        # 模板参考值（example.com / zhangsan 等）不算已设置：录入界面明确提示替换，避免被当成真实值
        if ($required -and $ServiceEnabled) { return '未设置（必填；当前是模板参考值，需替换为真实值）' }
        return '未设置（当前是模板参考值，需替换为真实值）'
    }
    if ($required -and $ServiceEnabled) { return '未设置（必填）' }
    if ($required) { return '未设置（可留空：服务已禁用；启用后为必填）' }
    if ($sensitive) { return '未设置' }
    if ($when) { return ('未设置（可留空：{0} 部署时留空）' -f $Deployment) }
    return '未设置（可留空）'
}

function Read-McpSuiteFieldValue {
    <#
    .SYNOPSIS
        按字段类型读取一个新值。
    .OUTPUTS
        @{ Done = $false }：直接回车，保留当前值；
        @{ Done = $true; Value = <新值> }：写入新值（输入 - 表示清空）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Field)

    $keep = @{ Done = $false }
    $kind = "$($Field.Kind)"
    if ($kind -eq 'bool') {
        while ($true) {
            $v = (Read-McpInput -Prompt '请输入新值（y=是 / n=否；直接回车保留当前值）').Trim()
            if ($v -eq '') { return $keep }
            if ($v -match '^(?i:y|yes|是|true|1)$') { return @{ Done = $true; Value = $true } }
            if ($v -match '^(?i:n|no|否|false|0)$') { return @{ Done = $true; Value = $false } }
            Write-Host '无法识别：请输入 y 或 n。'
        }
    }
    if ($kind -eq 'choice') {
        while ($true) {
            $v = (Read-McpInput -Prompt ('请输入新值（{0}；直接回车保留当前值）' -f ($Field.Choices -join ' / '))).Trim().ToLowerInvariant()
            if ($v -eq '') { return $keep }
            if (@($Field.Choices) -contains $v) { return @{ Done = $true; Value = $v } }
            Write-Host ('无法识别：只能是 {0}。' -f ($Field.Choices -join ' 或 '))
        }
    }
    if ($kind -eq 'url') {
        while ($true) {
            $v = (Read-McpInput -Prompt '请输入新值（以 http:// 或 https:// 开头；直接回车保留当前值，输入 - 清空）').Trim()
            if ($v -eq '') { return $keep }
            if ($v -eq '-') { return @{ Done = $true; Value = '' } }
            if ($v -match '^https?://\S+$') {
                $clean = $v.TrimEnd('/')
                if ($clean -ne $v) { Write-Host '已自动去掉末尾斜杠。' }
                return @{ Done = $true; Value = $clean }
            }
            Write-Host '地址必须以 http:// 或 https:// 开头，且不能包含空格。'
        }
    }
    if ($kind -eq 'text') {
        $v = Read-McpInput -Prompt '请输入新值（直接回车保留当前值，输入 - 清空）'
        if ([string]::IsNullOrEmpty($v)) { return $keep }
        if ($v.Trim() -eq '-') { return @{ Done = $true; Value = '' } }
        return @{ Done = $true; Value = $v.Trim() }
    }
    if ($kind -eq 'secret') {
        $v = Read-McpSecret -Prompt '请输入新值（输入不回显；直接回车保留当前值，输入 - 清空）'
        if ([string]::IsNullOrEmpty($v)) { return $keep }
        if ($v.Trim() -eq '-') { return @{ Done = $true; Value = '' } }
        return @{ Done = $true; Value = $v.Trim() }
    }
    if ($kind -eq 'list') {
        $v = Read-McpInput -Prompt '请输入新值（多个值用英文逗号分隔；直接回车保留当前值，输入 - 清空）'
        if ([string]::IsNullOrEmpty($v)) { return $keep }
        if ($v.Trim() -eq '-') { return @{ Done = $true; Value = @() } }
        $items = @($v -split '[,，]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        return @{ Done = $true; Value = $items }
    }
    return $keep
}

function Get-McpSuiteSectionFlag {
    # 读取配置段中的开关值（enabled 必须是布尔值才返回 true）
    param($Section, [string]$Name)
    if ($null -eq $Section) { return $false }
    $key = Find-McpSuiteSectionKey -Section $Section -Name $Name
    if (-not $key) { return $false }
    return ($Section[$key] -is [bool] -and $Section[$key])
}

<#
.SYNOPSIS
    输出某服务的就绪检查结果；未就绪时缺失字段以中文名列出（另附字段路径，便于在文件中定位）。
#>
function Write-McpSuiteReadyReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Key)

    $r = Test-McpSuiteConfigReady -Key $Key | Select-Object -First 1
    if ($r.Ready) {
        Write-Host ('就绪检查：{0} 已就绪，可执行连通性测试，或由 Host 按需拉起。' -f $r.DisplayName)
        return
    }
    if ($r.State -eq '已禁用') {
        Write-Host ('就绪检查：{0} 已在统一配置中禁用（enabled=false）。' -f $r.DisplayName)
        return
    }
    $missing = @($r.Missing)
    if ($missing.Count -gt 0) {
        # 逐字段列出“中文名（字段路径）：问题说明”，占位符与模板参考值分开提示
        Write-Host '就绪检查：未就绪。以下字段需要处理：'
        foreach ($line in (Get-McpSuiteReadyIssueLines -Ready $r)) { Write-Host ('  - ' + $line) }
    }
    else {
        Write-Host ('就绪检查：未就绪（{0}）。' -f $r.Reason)
    }
    Write-Host '可重新进入录入界面补齐，或直接编辑 mcp.config.json。'
}

function Show-McpSuiteConfigOverview {
    # 四个服务在统一配置中的就绪状态
    Write-Host ''
    Write-Host '==== MCP 服务配置（统一配置 mcp.config.json）===='
    foreach ($r in (Test-McpSuiteConfigReady)) {
        $line = '  [{0}] {1}：{2}' -f $r.Code, $r.DisplayName, $r.State
        if (-not $r.Ready) {
            if (@($r.Missing).Count -gt 0) {
                $line += '（缺失：' + ((@($r.Missing) | ForEach-Object { Get-McpSuiteFieldLabel -Path $_ }) -join '、') + '）'
            }
            elseif ($r.Reason) { $line += ' —— ' + $r.Reason }
        }
        Write-Host $line
    }
    Write-Host ('统一配置文件：{0}' -f (Get-McpSuiteConfigPath))
}

<#
.SYNOPSIS
    对指定服务逐字段录入统一配置（每个字段先展示说明、参考值与当前状态）。

.DESCRIPTION
    每录入一个字段即原子写回 mcp.config.json；中途中断时文件仍可解析，已写入的字段保留。
    录入结束后输出就绪检查；已就绪时询问是否执行连通性测试。

.PARAMETER Code
    服务代号（A-D）。

.OUTPUTS
    $true 表示完整走完录入流程；$false 表示已取消或中途停止。
#>
function Invoke-McpSuiteFieldEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Code)

    $svc = Get-McpServiceByCode -Code $Code
    if (-not $svc) {
        Write-Host ('未知的配置服务代号：{0}（可用：{1}）' -f $Code, ((Get-McpServices | ForEach-Object { $_.Code }) -join ' / '))
        return $false
    }
    $canon = "$($svc.ConfigKey)".ToLowerInvariant()
    $fields = Get-McpSuiteFieldCatalog -Key $canon
    try {
        $section = Get-McpSuiteConfigSection -Key $canon -AllowMissing
    }
    catch {
        Write-Host $_.Exception.Message
        return $false
    }
    $hints = Get-McpSuiteConfigHints -Key $canon
    $reference = Get-McpSuiteConfigReference -Key $canon

    Write-Host ''
    Write-Host ('---- 录入 {0}（services.{1}）----' -f $svc.DisplayName, $canon)
    Write-Host '直接回车保留当前值；输入 - 清空该字段。'

    $index = 0
    $stopped = $false
    $stopReason = ''
    foreach ($f in $fields) {
        $index++
        $name = $f.Name
        $path = 'services.{0}.{1}' -f $canon, $name

        $current = $null
        if ($null -ne $section -and $section.Contains($name)) { $current = $section[$name] }
        $deployment = ''
        if ($null -ne $section) { $deployment = Get-McpSuiteSectionFlagText -Section $section -Name 'deployment' }

        Write-Host ''
        Write-Host ('── [{0}/{1}] {2} ── {3}' -f $index, $fields.Count, $path, $f.Label)
        $hint = ''
        if ($hints.Contains($name)) { $hint = "$($hints[$name])" }
        if ($hint) { Write-Host ('说明：' + $hint) }
        Write-Host ('参考值：' + (Format-McpSuiteValue -Value $reference[$name]))
        Write-Host ('当前状态：' + (Get-McpSuiteFieldStatusText -Field $f -Value $current -ServiceEnabled (Get-McpSuiteSectionFlag -Section $section -Name 'enabled') -Deployment $deployment))
        if ("$($f.Kind)" -eq 'reserved') {
            Write-Host '该字段为预留字段，当前版本不录入（保持留空）。'
            continue
        }

        try {
            $answer = Read-McpSuiteFieldValue -Field $f
        }
        catch {
            # 例如标准输入被重定向时读取敏感字段：停止本服务的录入，不中断整个 mcpctl
            Write-Host ('读取失败：' + $_.Exception.Message)
            $stopReason = '读取失败'
            $stopped = $true
            break
        }
        if ($script:McpInputClosed) {
            Write-Host '输入已关闭，无法继续录入。'
            $stopReason = '输入已关闭'
            $stopped = $true
            break
        }
        if (-not $answer.Done) { continue }
        try {
            $null = Set-McpSuiteConfigSection -Key $canon -Values @{ $name = $answer.Value }
        }
        catch {
            Write-Host ('写入失败：' + $_.Exception.Message)
            $stopReason = '写入失败'
            $stopped = $true
            break
        }
        if ("$($f.Kind)" -eq 'secret') { Write-Host ('已写入 {0}（值不回显）' -f $path) }
        else { Write-Host ('已写入 {0}' -f $path) }
        # 重新读取：deployment 等字段的改动会影响后续字段的必填状态
        $section = Get-McpSuiteConfigSection -Key $canon
    }

    if ($stopped) {
        Write-Host ('已停止本服务的录入（{0}）；之前已写入的字段保留在统一配置文件中。' -f $stopReason)
        return $false
    }

    Write-McpSuiteReadyReport -Key $canon
    $ready = Test-McpSuiteConfigReady -Key $canon | Select-Object -First 1
    if ($ready.Ready -and (Read-McpYesNo -Prompt ('是否执行 {0} 的连通性测试' -f $svc.DisplayName))) {
        $null = Invoke-McpConnectivityTest -Code $svc.Code
    }
    return $true
}

function Get-McpSuiteSectionFlagText {
    # 读取配置段中的枚举值（小写）；缺失或不是字符串时返回空串
    param($Section, [string]$Name)
    if ($null -eq $Section) { return '' }
    $key = Find-McpSuiteSectionKey -Section $Section -Name $Name
    if (-not $key -or $Section[$key] -isnot [string]) { return '' }
    return $Section[$key].Trim().ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# 从旧配置导入
# ---------------------------------------------------------------------------

function Get-McpLegacyFiles {
    # 递归列出目录下的匹配文件，跳过依赖目录（node_modules / venv / bin 等）
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string]$Filter)

    $excluded = @('node_modules', 'venv', '.venv', 'bin', '.git', '__pycache__')
    $found = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue)) { [void]$found.Add($f) }
    foreach ($sub in (Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($excluded -contains $sub.Name) { continue }
        foreach ($f in (Get-McpLegacyFiles -Directory $sub.FullName -Filter $Filter)) { [void]$found.Add($f) }
    }
    return ,($found.ToArray())
}

function Get-McpSuiteRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Root)
    if (-not $Root) { return $Path }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($fullRoot.Length).TrimStart('\', '/')
    }
    return $full
}

function ConvertFrom-McpLegacyJsonConfig {
    <#
    .SYNOPSIS
        把旧的分服务 JSON 配置映射为统一配置字段（只取认识的字段，不解析预留字段 instances）。
    .OUTPUTS
        [ordered]@{}（字段名 → 值）；文件不是合法 JSON 时返回 $null。
    #>
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Path)

    try {
        $obj = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ($null -eq $obj) { return $null }

    $result = [ordered]@{}
    $allowed = @($script:McpSuiteFieldCatalog[$Key] | ForEach-Object { $_.Name } | Where-Object { $_ -ne 'instances' })
    $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })

    if ($Key -eq 'gerrit' -and ($names -contains 'gerrit_hosts')) {
        # 上游嵌套格式：gerrit_hosts[0] = { name; external_url; authentication = { username; auth_token } }
        $host0 = @($obj.gerrit_hosts) | Select-Object -First 1
        if ($null -ne $host0) {
            $result['instanceName'] = "$($host0.name)"
            $result['baseUrl'] = "$($host0.external_url)"
            $result['username'] = "$($host0.authentication.username)"
            $result['httpPassword'] = "$($host0.authentication.auth_token)"
        }
    }
    else {
        foreach ($p in $obj.PSObject.Properties) {
            if ($allowed -contains $p.Name) { $result[$p.Name] = $p.Value }
        }
    }

    # 旧配置只记个人访问令牌，没有部署类型与邮箱：按私有部署（server）处理
    if ($Key -eq 'atlassian' -and -not $result.Contains('deployment')) { $result['deployment'] = 'server' }

    # 去掉空值与类型不符的值（布尔字段接受 true / false 字符串）
    foreach ($name in @($result.Keys)) {
        $value = $result[$name]
        $field = $script:McpSuiteFieldCatalog[$Key] | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ("$($field.Kind)" -eq 'bool') {
            if ($value -isnot [bool]) { $result.Remove($name) }
            continue
        }
        if (-not (Test-McpSuiteValueFilled -Value $value)) { $result.Remove($name) }
    }
    return ,$result
}

function ConvertFrom-McpLegacyEnvConfig {
    # 解析 mcp-github/.env（KEY=VALUE），映射为统一配置的 github 段字段；空值不导入
    param([Parameter(Mandatory = $true)][string]$Path)

    $map = @{ GITHUB_BASE_URL = 'baseUrl'; GITHUB_PAT = 'pat'; GITHUB_SCOPE = 'scope' }
    $result = [ordered]@{}
    try {
        $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    }
    catch {
        return ,$result
    }
    foreach ($line in $lines) {
        $t = "$line".Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        if (-not $map.ContainsKey($k)) { continue }
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        if ($v -eq '') { continue }
        $result[$map[$k]] = $v
    }
    return ,$result
}

<#
.SYNOPSIS
    扫描各服务目录，找出可迁移到统一配置的旧配置文件（*_config.json 与 mcp-github/.env）。

.PARAMETER Root
    仓库根目录（默认取注册表中的仓库根）。

.OUTPUTS
    数组，每项 @{ Key = 配置段名; Path = 文件完整路径; Values = [ordered]@{ 字段名 → 值 } }。
    不是合法 JSON 的旧文件只提示、不收录。
#>
function Find-McpLegacyConfigSources {
    [CmdletBinding()]
    param([string]$Root)

    if (-not $Root) { $Root = Get-McpRepoRoot }
    $sources = New-Object System.Collections.ArrayList
    foreach ($svc in (Get-McpServices)) {
        $canon = "$($svc.ConfigKey)".ToLowerInvariant()
        $dir = Join-Path $Root $svc.Id
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        foreach ($f in (Get-McpLegacyFiles -Directory $dir -Filter '*_config.json')) {
            if ($f.Name -like '*.sample.json') { continue }
            $values = ConvertFrom-McpLegacyJsonConfig -Key $canon -Path $f.FullName
            if ($null -eq $values) {
                Write-Host ('旧配置不是合法 JSON，已跳过：{0}' -f (Get-McpSuiteRelativePath -Path $f.FullName -Root $Root))
                continue
            }
            if ($values.Count -eq 0) { continue }
            [void]$sources.Add([ordered]@{ Key = $canon; Path = $f.FullName; Values = $values })
        }

        if ($canon -eq 'github') {
            $envFile = Join-Path $dir '.env'
            if (Test-Path -LiteralPath $envFile -PathType Leaf) {
                $values = ConvertFrom-McpLegacyEnvConfig -Path $envFile
                if ($values.Count -gt 0) { [void]$sources.Add([ordered]@{ Key = $canon; Path = $envFile; Values = $values }) }
            }
        }
    }
    return ,($sources.ToArray())
}

<#
.SYNOPSIS
    从旧配置导入：逐项询问「覆盖 / 保留」，把旧配置字段写入统一配置 mcp.config.json。

.DESCRIPTION
    - 旧文件不自动删除（其中含凭证，提示用户确认后自行删除或移出仓库目录）；
    - 控制台只显示字段名，不显示任何取值；
    - 统一配置中已有值的字段询问是否覆盖，未设置的询问是否导入。

.PARAMETER Root
    仓库根目录（默认取注册表中的仓库根）。

.OUTPUTS
    实际写入统一配置的字段数。
#>
function Invoke-McpLegacyConfigImport {
    [CmdletBinding()]
    param([string]$Root)

    if (-not $Root) { $Root = Get-McpRepoRoot }
    $sources = Find-McpLegacyConfigSources -Root $Root
    if ($sources.Count -eq 0) {
        Write-Host '未发现旧配置文件（各服务目录下的 *_config.json、mcp-github/.env），无需迁移。'
        return 0
    }

    $imported = 0
    foreach ($src in $sources) {
        $canon = $src.Key
        Write-Host ''
        Write-Host ('发现旧配置：{0} → services.{1}（可迁移 {2} 个字段：{3}；值不显示）' -f (Get-McpSuiteRelativePath -Path $src.Path -Root $Root), $canon, $src.Values.Count, (@($src.Values.Keys) -join '、'))
        $section = Get-McpSuiteConfigSection -Key $canon -AllowMissing
        foreach ($name in @($src.Values.Keys)) {
            $label = Get-McpSuiteFieldLabel -Path ('services.{0}.{1}' -f $canon, $name)
            $has = ($null -ne $section -and $section.Contains($name))
            if ($has -and (Test-McpSuiteValueFilled -Value $section[$name])) {
                $prompt = 'services.{0}.{1}（{2}）在统一配置中已有值：是否用旧配置覆盖？' -f $canon, $name, $label
            }
            else {
                $prompt = '是否把旧配置导入 services.{0}.{1}（{2}）？统一配置当前未设置。' -f $canon, $name, $label
            }
            if (-not (Read-McpYesNo -Prompt $prompt)) {
                Write-Host '  已保留统一配置中的当前值。'
                continue
            }
            try {
                $null = Set-McpSuiteConfigSection -Key $canon -Values @{ $name = $src.Values[$name] }
                $imported++
                Write-Host ('  已写入 services.{0}.{1}' -f $canon, $name)
            }
            catch {
                Write-Host ('  写入失败：' + $_.Exception.Message)
            }
        }
    }

    Write-Host ''
    Write-Host ('本次共导入 {0} 个字段。' -f $imported)
    Write-Host '旧配置文件未删除（已保留在原位置）：其中含凭证，请确认迁移无误后自行删除或移出仓库目录，切勿提交到 Git。'
    return $imported
}

# ---------------------------------------------------------------------------
# 连通性测试（Gerrit 已实装；其余服务以握手探活为准）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    执行指定服务的连通性测试，返回 { Code; Tested; Message }。

.DESCRIPTION
    Gerrit：只读 REST 验证（GET /a/accounts/self，HTTP Basic），凭证取自统一配置
    mcp.config.json 的 services.gerrit 段；配置未就绪时不发请求。
    其余服务：暂无专用连通性测试，提示使用菜单 1 的握手探活。
#>
function Invoke-McpConnectivityTest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Code)

    $svc = Get-McpServiceByCode -Code $Code
    if (-not $svc) { throw "未知服务代号：$Code" }
    $result = [pscustomobject]@{ Code = $svc.Code; Tested = $false; Message = '' }

    if ($svc.Id -ne 'mcp-gerrit') {
        $result.Message = '[占位] {0} 暂无专用连通性测试，可使用菜单 1 的“握手探活”验证。' -f $svc.DisplayName
        Write-Host $result.Message
        return $result
    }

    # —— Gerrit：只读 REST 验证（GET /a/accounts/self，HTTP Basic）——
    $ready = Test-McpSuiteConfigReady -Key $svc.ConfigKey | Select-Object -First 1
    if (-not $ready.Ready) {
        $detail = (@(Get-McpSuiteReadyIssueLines -Ready $ready) -join '；')
        if (-not $detail) { $detail = $ready.Reason }
        $result.Message = '配置未就绪（' + $detail + '）：请先运行配置向导（菜单 4）补齐 Gerrit 的实例地址、用户名与 HTTP 凭证。'
        Write-Host $result.Message
        return $result
    }
    $section = Get-McpSuiteConfigSection -Key $svc.ConfigKey
    $baseUrl    = "$($section['baseUrl'])"
    $username   = "$($section['username'])"
    $credential = "$($section['httpPassword'])"
    $url = ($baseUrl.TrimEnd('/')) + '/a/accounts/self'
    $pair = '{0}:{1}' -f $username, $credential
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 20 -UseBasicParsing
        $body = (($resp.Content) -replace "^\)\]\}'\s*", '') | ConvertFrom-Json
        $who = if ($body.username) { $body.username } else { $body.name }
        $result.Tested = $true
        $result.Message = '连通成功：账号 {0}（_account_id {1}）' -f $who, $body._account_id
        Write-Host $result.Message
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401) { $result.Message = '连通失败：认证被拒绝（401），请检查用户名与 HTTP 凭证。' }
        elseif ($status) { $result.Message = '连通失败：HTTP {0}' -f $status }
        else { $result.Message = '连通失败：' + $_.Exception.Message }
        Write-Host $result.Message
    }
    return $result
}

# ---------------------------------------------------------------------------
# 配置向导主入口
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    配置向导主入口：确保统一配置文件存在，然后循环提供录入 / 导入 / 连通性测试菜单。

.DESCRIPTION
    - mcp.config.json 不存在：提示「将从 sample 生成」，经确认后用模板生成；
    - 文件存在但无法解析：向导不覆盖，提示手工修复后返回；
    - 菜单：[1] 录入 / 修改服务配置（逐字段）  [2] 从旧配置导入  [3] 连通性测试  [0] 返回。
#>
function Invoke-McpConfigWizard {
    [CmdletBinding()]
    param()

    $path = Get-McpSuiteConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ''
        Write-Host ('统一配置文件不存在：{0}' -f $path)
        Write-Host '将从模板 mcp.config.sample.json 生成统一配置文件（其中的参考值需逐项替换为你的真实配置）。'
        if (-not (Read-McpYesNo -Prompt '是否现在从模板生成 mcp.config.json')) {
            Write-Host '已取消：也可以稍后手动复制模板并填写。'
            return
        }
        try {
            $null = Initialize-McpSuiteConfigFromSample
        }
        catch {
            Write-Host ('生成失败：' + $_.Exception.Message)
            return
        }
        # 模板参考值（example / zhangsan 字样）不算已填写：生成后立即提醒，避免误以为只差凭证
        Write-Host ($script:McpSuiteInitializedNotice -f $path)
        Write-Host '请逐字段录入。'
    }

    try {
        $null = Get-McpSuiteConfig
    }
    catch {
        Write-Host ''
        Write-Host ('统一配置文件无法读取：' + $_.Exception.Message)
        Write-Host '配置向导不会覆盖无法解析的文件：请先手动修复该文件，或把它移走后重新运行向导。'
        return
    }

    # 旧版文件可能带 _hints 段：mcp.config.json 不再保留它，进入向导时顺手清掉。
    # 只去掉这一段，其余配置内容不变；失败也不影响录入（下次保存配置时仍会移除）。
    try {
        if (Remove-McpSuiteLegacyHints) {
            Write-Host '已移除统一配置中旧版遗留的 _hints 段：字段提示统一取自模板 mcp.config.sample.json 与配置字段说明文档，配置内容未变。'
        }
    }
    catch {
        Write-Host ('提示：统一配置仍带旧版遗留的 _hints 段，本次未能自动移除（' + $_.Exception.Message + '）。不影响录入，下次保存配置时会自动移除。')
    }

    # 字段目录自检：与模板不一致时直接报错，避免录入界面与文件脱节
    foreach ($key in (Get-McpSuiteServiceKeys)) {
        try { $null = Get-McpSuiteFieldCatalog -Key $key }
        catch {
            Write-Host ('配置向导不可用：' + $_.Exception.Message)
            return
        }
    }

    while ($true) {
        Show-McpSuiteConfigOverview
        Write-Host ''
        Write-Host '  [1] 录入 / 修改服务配置（逐字段）'
        Write-Host '  [2] 从旧配置导入（各服务目录下原有的 *_config.json、mcp-github/.env）'
        Write-Host '  [3] 连通性测试'
        Write-Host '  [0] 返回'
        $choice = (Read-McpInput -Prompt '请选择').Trim()
        if ($script:McpInputClosed) {
            Write-Host '输入已关闭，退出配置向导。'
            return
        }
        switch ($choice) {
            '1' {
                $code = (Read-McpInput -Prompt '请输入服务代号（A-D），直接回车取消').Trim()
                if ($code) { $null = Invoke-McpSuiteFieldEntry -Code $code }
            }
            '2' {
                $null = Invoke-McpLegacyConfigImport
            }
            '3' {
                $code = (Read-McpInput -Prompt '请输入服务代号（A-D），直接回车取消').Trim()
                if ($code) {
                    try { $null = Invoke-McpConnectivityTest -Code $code }
                    catch { Write-Host $_.Exception.Message }
                }
            }
            '0' { return }
            default { Write-Host '无效选择，请输入 0-3。' }
        }
    }
}

# 直接运行本文件时进入配置向导（被 dot-source 时不触发）
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-McpConfigWizard
}
