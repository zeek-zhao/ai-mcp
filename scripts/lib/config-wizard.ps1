#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 配置入口与连通性测试（M2 建立；T-CFG-02 起切换为统一配置）。

.DESCRIPTION
    统一配置改造分两步：
      - T-CFG-02（当前版本）：就绪判定与 Gerrit 连通测试改为读取统一配置 mcp.config.json；
        逐字段录入界面暂停，提示用户直接编辑统一配置文件。
      - T-CFG-04（后续版本）：改为单文件逐字段录入（展示参考值与中文提示），并提供
        “从旧配置导入”。
    统一配置的读写一律经 scripts/lib/suite-config.ps1，本文件不直接解析配置文件。

    安全约束：任何控制台输出与日志都不得出现明文凭证；连通测试的报错不复述凭证。

.EXAMPLE
    . (Join-Path $PSScriptRoot 'lib\config-wizard.ps1')
    Invoke-McpConfigWizard
    Invoke-McpConnectivityTest -Code A
#>

# 加载统一配置模块（内部已加载注册表）
. (Join-Path -Path $PSScriptRoot -ChildPath 'suite-config.ps1')

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
        $detail = $ready.Reason
        if (@($ready.Missing).Count -gt 0) { $detail += '（缺失：' + (@($ready.Missing) -join '、') + '）' }
        $result.Message = '配置未就绪（' + $detail + '）：请先在 mcp.config.json 的 services.gerrit 段填写实例地址、用户名与 HTTP 凭证。'
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
# 配置入口（过渡版本：展示状态 + 引导直接编辑统一配置）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    展示四个服务在统一配置中的就绪状态，并引导用户编辑 mcp.config.json。
#>
function Invoke-McpConfigWizard {
    [CmdletBinding()]
    param()

    $path = Get-McpSuiteConfigPath
    Write-Host ''
    Write-Host '==== MCP 服务配置（统一配置 mcp.config.json）===='
    foreach ($r in (Test-McpSuiteConfigReady)) {
        Write-Host ('  [{0}] {1}：{2}' -f $r.Code, $r.DisplayName, $r.State)
        if (-not $r.Ready -and $r.Reason) {
            $line = '      ' + $r.Reason
            if (@($r.Missing).Count -gt 0) { $line += '（缺失：' + (@($r.Missing) -join '、') + '）' }
            Write-Host $line
        }
    }
    Write-Host ('统一配置文件：{0}' -f $path)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host '该文件尚不存在：请复制模板 mcp.config.sample.json 为 mcp.config.json 后填写。'
    }
    Write-Host '逐字段录入界面正在改造为单文件录入（任务 T-CFG-04），当前请直接编辑上述文件。'
    Write-Host '字段含义、参考值与获取方式见 docs/services/配置字段说明.md。'

    if (Read-McpYesNo -Prompt '是否执行连通性测试') {
        $code = Read-McpInput -Prompt '请输入服务代号（A-D），直接回车取消'
        if ($code) { $null = Invoke-McpConnectivityTest -Code $code }
    }
}

# 直接运行本文件时进入配置入口（被 dot-source 时不触发）
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-McpConfigWizard
}
