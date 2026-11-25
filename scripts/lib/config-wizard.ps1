#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 全中文分步配置向导（M2）。

.DESCRIPTION
    引导用户完成各服务的本地配置：
      1. 列出四个受管服务供选择；
      2. 本地配置不存在时从模板复制；已存在时询问“覆盖 / 保留退出”；
      3. 按服务逐条录入参数，Token/密码类输入隐藏不回显；
      4. 写入本地配置（真实凭证仅落盘本地文件，不入库）；
      5. 提供“连通性测试”入口占位（真实接口在 M5–M8 实现）；
      6. 计算配置就绪标记：配置文件存在且必填项非空（占位符 <...> 视为未填）。

    用法（脚本内调用）：
        . (Join-Path $PSScriptRoot 'lib\config-wizard.ps1')
        Invoke-McpConfigWizard              # 交互式选择服务
        Invoke-McpConfigWizard -ServiceCode A
        Get-McpConfigReadiness              # 全部服务的就绪状态

    直接运行本文件（pwsh -File / 右键运行）即进入交互向导。

.NOTES
    安全约束：任何控制台输出与（未来里程碑的）日志都不得出现明文凭证；
    敏感值展示一律以 <已隐藏> 代替。
#>

# 加载注册表（服务清单与路径）
. (Join-Path -Path $PSScriptRoot -ChildPath 'registry.ps1')

# ---------------------------------------------------------------------------
# 各服务录入字段定义（Key 与模板字段一致）
#   Format    配置文件格式：json / env
#   Key       字段名（json 顶层键 / env 变量名）
#   Prompt    中文提示
#   Required  是否必填（必填缺失 → 就绪标记“未配置就绪”）
#   Sensitive 敏感字段（输入隐藏、展示遮蔽）
#   Kind      text 单值 / choice 选项 / list 逗号分隔列表 / bool 是否
# ---------------------------------------------------------------------------
$script:McpConfigSchemas = @{
    'mcp-gerrit' = @{
        Format = 'json'
        Fields = @(
            @{ Key = 'instanceName'; Prompt = '实例显示名称（可留空）';                          Required = $false; Sensitive = $false; Kind = 'text' }
            @{ Key = 'baseUrl';      Prompt = '实例地址（如 https://gerrit.example.com）';      Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'username';     Prompt = '用户名';                                        Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'credential';   Prompt = 'HTTP 凭证（Gerrit 设置中的 HTTP Password）';    Required = $true;  Sensitive = $true;  Kind = 'text' }
        )
        # gerrit-mcp-server 1.0.8 要求嵌套配置结构（见 mcp-gerrit/gerrit_config.sample.json）：
        # BuildJson 用扁平录入值组装完整 JSON；JsonGet 从嵌套结构读回字段值（就绪判定用）。
        BuildJson = { param($Values)
            $name = if ($Values['instanceName']) { $Values['instanceName'] } else { 'Gerrit' }
            $cfg = [ordered]@{
                default_gerrit_base_url = $Values['baseUrl']
                gerrit_hosts = @(
                    [ordered]@{
                        name = $name
                        external_url = $Values['baseUrl']
                        authentication = [ordered]@{
                            type = 'http_basic'
                            username = $Values['username']
                            auth_token = $Values['credential']
                        }
                    }
                )
            }
            return ($cfg | ConvertTo-Json -Depth 10)
        }
        JsonGet = { param($Json, $Key)
            switch ($Key) {
                'baseUrl'      { return $Json.default_gerrit_base_url }
                'instanceName' { if ($Json.gerrit_hosts -and @($Json.gerrit_hosts).Count -gt 0) { return @($Json.gerrit_hosts)[0].name } }
                'username'     { if ($Json.gerrit_hosts -and @($Json.gerrit_hosts).Count -gt 0) { return @($Json.gerrit_hosts)[0].authentication.username } }
                'credential'   { if ($Json.gerrit_hosts -and @($Json.gerrit_hosts).Count -gt 0) { return @($Json.gerrit_hosts)[0].authentication.auth_token } }
            }
            return $null
        }
    }
    'mcp-github' = @{
        Format = 'env'
        Fields = @(
            @{ Key = 'GITHUB_BASE_URL'; Prompt = '实例地址（GitHub 或 GitHub Enterprise）'; Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'GITHUB_PAT';      Prompt = '个人访问令牌（PAT）';                     Required = $true;  Sensitive = $true;  Kind = 'text' }
            @{ Key = 'GITHUB_SCOPE';    Prompt = '组织 / 仓库范围（可留空）';               Required = $false; Sensitive = $false; Kind = 'text' }
        )
    }
    'mcp-jenkins' = @{
        Format = 'json'
        Fields = @(
            @{ Key = 'baseUrl';   Prompt = '实例地址（如 https://jenkins.example.com）'; Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'username';  Prompt = '用户名';                                     Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'apiToken';  Prompt = 'API Token';                                  Required = $true;  Sensitive = $true;  Kind = 'text' }
            @{ Key = 'readOnly';  Prompt = '只读模式（建议保持开启）';                   Required = $false; Sensitive = $false; Kind = 'bool' }
            @{ Key = 'instances'; Prompt = '多实例地址（逗号分隔，可留空）';             Required = $false; Sensitive = $false; Kind = 'list' }
        )
    }
    'mcp-atlassian' = @{
        Format = 'json'
        Fields = @(
            @{ Key = 'jiraBaseUrl';       Prompt = 'Jira 实例地址';               Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'confluenceBaseUrl'; Prompt = 'Confluence 实例地址';         Required = $true;  Sensitive = $false; Kind = 'text' }
            @{ Key = 'personalAccessToken'; Prompt = '个人访问令牌（PAT）';       Required = $true;  Sensitive = $true;  Kind = 'text' }
            @{ Key = 'projectScope';      Prompt = '项目范围（逗号分隔，可留空）'; Required = $false; Sensitive = $false; Kind = 'list' }
            @{ Key = 'spaceScope';        Prompt = '空间范围（逗号分隔，可留空）'; Required = $false; Sensitive = $false; Kind = 'list' }
        )
    }
}

# 占位符形态（模板默认值，如 <https://...>）：就绪判定视为“未填写”
$script:McpPlaceholderPattern = '^\s*<.*>\s*$'

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
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if ($secure.Length -eq 0) { return $null }
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
    return ($v -match '^(y|Y|是)$')
}

# ---------------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    将模板复制为本地配置（模板与本地路径取自注册表）。
#>
function Copy-McpConfigTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $tpl = $Service.ConfigTemplateFull
    $dst = $Service.LocalConfigFull
    if (-not (Test-Path -LiteralPath $tpl)) {
        throw "模板不存在：$tpl"
    }
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $tpl -Destination $dst -Force
    Write-Host "已从模板生成本地配置：$($Service.LocalConfig)"
}

<#
.SYNOPSIS
    读取本地配置中某字段的现值（json 顶层键 / env 变量；不存在返回 $null）。
#>
function Get-McpConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $path = $Service.LocalConfigFull
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if ($script:McpConfigSchemas[$Service.Id].Format -eq 'env') {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ($line -match "^$([regex]::Escape($Key))=(.*)$") { return $Matches[1] }
        }
        return $null
    }
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $jsonGet = $script:McpConfigSchemas[$Service.Id].JsonGet
    if ($jsonGet) { return & $jsonGet $json $Key }
    $prop = $json.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

<#
.SYNOPSIS
    将录入值写入本地配置（json 逐键写入 / env 逐行替换，保留注释与其他行）。

.DESCRIPTION
    仅写入本地配置文件；文件已被 .gitignore 排除，不入库。
    写盘使用 UTF-8 无 BOM（部分运行时解析 JSON 不接受 BOM）。
#>
function Write-McpConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )
    $path = $Service.LocalConfigFull
    $format = $script:McpConfigSchemas[$Service.Id].Format
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if ($format -eq 'env') {
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
        foreach ($key in $Values.Keys) {
            $idx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^$([regex]::Escape($key))=") { $idx = $i; break }
            }
            $newLine = ('{0}={1}' -f $key, $Values[$key])
            if ($idx -ge 0) { $lines[$idx] = $newLine } else { $lines += $newLine }
        }
        [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", $utf8NoBom)
        return
    }

    # json 格式（BuildJson：嵌套结构由 schema 专属函数组装）
    $buildJson = $script:McpConfigSchemas[$Service.Id].BuildJson
    if ($buildJson) {
        $text = & $buildJson $Values
        [IO.File]::WriteAllText($path, $text, $utf8NoBom)
        return
    }
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in $Values.Keys) {
        $prop = $json.PSObject.Properties[$key]
        if ($prop) { $prop.Value = $Values[$key] }
        else { $json | Add-Member -MemberType NoteProperty -Name $key -Value $Values[$key] }
    }
    $text = $json | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# 就绪标记
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    计算服务配置就绪标记：配置文件存在且必填项非空（占位符视为未填）。

.PARAMETER Code
    服务代号（A/B/C/D）；省略时返回全部服务。
#>
function Get-McpConfigReadiness {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    foreach ($svc in $services) {
        $missing = @()
        $exists = Test-Path -LiteralPath $svc.LocalConfigFull
        if ($exists) {
            foreach ($f in $script:McpConfigSchemas[$svc.Id].Fields) {
                if (-not $f.Required) { continue }
                $v = Get-McpConfigValue -Service $svc -Key $f.Key
                if ([string]::IsNullOrEmpty("$v") -or "$v" -match $script:McpPlaceholderPattern) {
                    $missing += $f.Key
                }
            }
        }
        else {
            $missing = @($script:McpConfigSchemas[$svc.Id].Fields | Where-Object Required | ForEach-Object Key)
        }
        [pscustomobject]@{
            Code         = $svc.Code
            Id           = $svc.Id
            DisplayName  = $svc.DisplayName
            ConfigExists = $exists
            Ready        = ($exists -and $missing.Count -eq 0)
            Missing      = $missing
        }
    }
}

# ---------------------------------------------------------------------------
# 连通性测试（M2 占位，真实实现在 M5–M8）
# ---------------------------------------------------------------------------

function Invoke-McpConnectivityTest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code)
    $svc = Get-McpServiceByCode -Code $Code
    if (-not $svc) { throw "未知服务代号：$Code" }
    if ($svc.Id -ne 'mcp-gerrit') {
        Write-Host "[占位] $($svc.DisplayName) 连通性测试将在 M6–M8 随服务接入时提供真实实现。"
        return [pscustomobject]@{
            Code    = $svc.Code
            Tested  = $false
            Message = '连通性测试为占位入口，将在 M6–M8 实现真实接口调用'
        }
    }
    # —— Gerrit：只读 REST 验证（GET /a/accounts/self，HTTP Basic）——
    $result = [pscustomobject]@{ Code = $svc.Code; Tested = $false; Message = '' }
    $baseUrl   = Get-McpConfigValue -Service $svc -Key 'baseUrl'
    $username  = Get-McpConfigValue -Service $svc -Key 'username'
    $credential = Get-McpConfigValue -Service $svc -Key 'credential'
    if (-not $baseUrl -or -not $username -or -not $credential) {
        $result.Message = '配置未就绪：请先运行配置向导完成实例地址、用户名与 HTTP 凭证录入。'
        Write-Host $result.Message
        return $result
    }
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
# 向导主流程
# ---------------------------------------------------------------------------

function Invoke-McpConfigWizard {
    [CmdletBinding()]
    param([string]$ServiceCode)

    while ($true) {
        # —— 选择服务 ——
        $svc = $null
        if ($ServiceCode) {
            $svc = Get-McpServiceByCode -Code $ServiceCode
            if (-not $svc) { throw "未知服务代号：$ServiceCode" }
        }
        else {
            Write-Host ''
            Write-Host '==== MCP 服务配置向导 ===='
            foreach ($r in (Get-McpConfigReadiness)) {
                $state = if ($r.Ready) { '已就绪' } elseif ($r.ConfigExists) { '未配置就绪' } else { '未生成配置' }
                Write-Host ("  [{0}] {1} —— {2}" -f $r.Code, $r.DisplayName, $state)
            }
            $pick = Read-McpInput -Prompt '请输入服务代号（A-D），Q 退出向导'
            if ($pick -match '^[qQ]$') { return }
            if (-not $pick) { continue }
            $svc = Get-McpServiceByCode -Code $pick
            if (-not $svc) { Write-Host '输入无效，请重新选择。'; continue }
        }

        Write-Host ''
        Write-Host ("---- 正在配置：{0}（目录 {1}，技术栈 {2}）----" -f $svc.DisplayName, $svc.Id, $svc.Stack)

        # —— 模板 → 本地配置（已存在时询问覆盖 / 保留退出）——
        if (Test-Path -LiteralPath $svc.LocalConfigFull) {
            Write-Host ("检测到本地配置已存在：{0}" -f $svc.LocalConfig)
            $mode = Read-McpInput -Prompt '请选择：[1] 覆盖（保留现有值重新逐项确认） [2] 保留现有配置并退出'
            if ($mode -ne '1') {
                Write-Host '已保留现有配置，退出向导。'
                if ($ServiceCode) { return }
                continue
            }
        }
        else {
            Copy-McpConfigTemplate -Service $svc
        }

        # —— 逐条录入 ——
        $values = @{}
        foreach ($f in $script:McpConfigSchemas[$svc.Id].Fields) {
            $current = Get-McpConfigValue -Service $svc -Key $f.Key
            $hasCurrent = (-not [string]::IsNullOrEmpty("$current"))

            switch ($f.Kind) {
                'choice' {
                    Write-Host ("{0}：" -f $f.Prompt)
                    for ($i = 0; $i -lt $f.Choices.Count; $i++) {
                        $mark = if ("$current" -eq $f.Choices[$i]) { '（当前）' } else { '' }
                        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $f.Choices[$i], $mark)
                    }
                    $pick = Read-McpInput -Prompt ('请选择序号（回车 = 保留 {0}）' -f $(if ($hasCurrent) { $current } else { '默认' }))
                    if ($pick) {
                        $idx = 0
                        if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $f.Choices.Count) {
                            $values[$f.Key] = $f.Choices[$idx - 1]
                        }
                        elseif ($f.Choices -contains $pick) { $values[$f.Key] = $pick }
                        else { Write-Host '选择无效，保留现有值。' }
                    }
                }
                'bool' {
                    $cur = if ("$current" -match '^(true|1|y)$') { '是' } elseif ($hasCurrent) { '否' } else { '是' }
                    $ans = Read-McpInput -Prompt ("{0}（y/N，回车 = 保留 {1}）" -f $f.Prompt, $cur)
                    if ($ans) { $values[$f.Key] = ($ans -match '^(y|Y|是|1|true)$') }
                }
                'list' {
                    $disp = if ($hasCurrent) { ($current -join ', ') } else { '' }
                    $ans = Read-McpInput -Prompt ("{0}（当前：{1}；回车 = 保留）" -f $f.Prompt, $(if ($disp) { $disp } else { '空' }))
                    if ($ans) {
                        $values[$f.Key] = @($ans -split '[,，;；]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    }
                }
                default {
                    if ($f.Sensitive) {
                        $hint = if ($hasCurrent) { '（回车 = 保留现有值）' } else { '（输入不回显）' }
                        $ans = Read-McpSecret -Prompt ("{0} {1}" -f $f.Prompt, $hint)
                        if ($ans) { $values[$f.Key] = $ans }
                    }
                    else {
                        $hint = if ($hasCurrent) { "（回车 = 保留 $current）" } else { '' }
                        $ans = Read-McpInput -Prompt ("{0} {1}" -f $f.Prompt, $hint)
                        if ($ans) { $values[$f.Key] = $ans }
                        elseif ($hasCurrent -and "$current" -match $script:McpPlaceholderPattern) {
                            # 现值仍是模板占位符（如 <https://...>）时，回车视为清空，
                            # 避免占位符残留进本地配置。
                            $values[$f.Key] = ''
                        }
                    }
                }
            }

            if ($values.ContainsKey($f.Key) -and $f.Sensitive) {
                Write-Host ("  已录入：{0} = <已隐藏>" -f $f.Key)
            }
        }

        # —— 写入并回执（不回显任何明文值）——
        if ($values.Count -gt 0) {
            Write-McpConfigFile -Service $svc -Values $values
            Write-Host ''
            Write-Host ("本地配置已写入：{0}（该文件不入 Git 仓库）" -f $svc.LocalConfig)
            foreach ($k in $values.Keys) {
                $f = $script:McpConfigSchemas[$svc.Id].Fields | Where-Object { $_.Key -eq $k }
                $shown = if ($f.Sensitive) { '<已隐藏>' } else { $values[$k] }
                if ($shown -is [array]) { $shown = $shown -join ', ' }
                Write-Host ("  {0} = {1}" -f $k, $shown)
            }
        }
        else {
            Write-Host '未修改任何字段。'
        }

        # —— 就绪标记 ——
        $r = Get-McpConfigReadiness -Code $svc.Code
        if ($r.Ready) { Write-Host "配置就绪标记：已就绪 ✔" }
        else {
            Write-Host '配置就绪标记：未配置就绪（以下必填项缺失或为占位符）：'
            foreach ($m in $r.Missing) { Write-Host ("  - {0}" -f $m) }
        }

        # —— 连通性测试入口（占位）——
        if (Read-McpYesNo -Prompt '是否执行连通性测试') {
            Invoke-McpConnectivityTest -Code $svc.Code | Out-Null
        }

        if ($ServiceCode) { return }
        if (-not (Read-McpYesNo -Prompt '是否继续配置其他服务')) { return }
        $ServiceCode = $null
    }
}

# 直接运行本文件时进入向导（被 dot-source 时不触发）
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-McpConfigWizard
}
