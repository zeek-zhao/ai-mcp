#Requires -Version 5.1
<#
.SYNOPSIS
    登录预检与环境自愈（M9；原「登录常驻管理」已随 ADR-006 取消）。

.DESCRIPTION
    预检：遍历服务注册表，检查运行时（Python / Node.js / npm / curl）、依赖环境（venv /
    node_modules / 本地二进制）、统一配置（文件可解析、启用服务的必填项已填）与启动命令
    （已回填且可定位），输出中文汇总；未通过项给出可直接执行的中文修复命令。
    结果保存到 logs\preflight-last.json（运行时产物，不入库），可再次查看。

    自愈：依赖环境缺失时可调用 Bootstrap「初始化缺失环境」。修复动作必须显式允许：
      - 交互式运行时逐次确认；
      - 或在 scripts\mcpctl.config.ps1 中设置 PreflightAutoBootstrap = $true 预先允许。
    自愈之外的修复（安装运行时、下载 GitHub 二进制、填写配置）只给出命令，不代为执行。

    进程边界（ADR-006）：预检与自愈均不启动、不托管任何 MCP 服务进程。

    登录触发：默认关闭（PreflightLoginTrigger = $false）。本工具不创建计划任务；
    如需登录时自动预检，由用户自行创建“仅预检”的任务，例如（普通用户权限，路径按本机实际修改）：
      schtasks /Create /SC ONLOGON /TN "mcpctl-preflight" /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File <仓库路径>\scripts\autostart.ps1"
    删除：
      schtasks /Delete /TN "mcpctl-preflight" /F

    直接运行：
      powershell -NoProfile -ExecutionPolicy Bypass -File scripts\autostart.ps1
          仅预检；退出码 0 = 全部通过，1 = 存在未通过项
      powershell -NoProfile -ExecutionPolicy Bypass -File scripts\autostart.ps1 -Heal
          预检后按配置或确认执行环境自愈

.NOTES
    仅预检时不产生副作用：不创建 venv / node_modules，不改配置，不下载二进制，不启动 MCP 进程。
    仅写操作日志与上次预检结果（均在仓库内 logs\ 目录，已被 .gitignore 排除）。
#>
[CmdletBinding()]
param(
    [switch]$Heal
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\registry.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\service-utils.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\config-wizard.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'bootstrap.ps1')

$script:McpPreflightLastResultFile = 'preflight-last.json'

$script:McpPreflightLevel = @{
    Pass = '通过'
    Fail = '未通过'
    Skip = '跳过'
    Info = '提示'
}

<#
.SYNOPSIS
    构造一条预检结果。
#>
function New-McpPreflightItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Item,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Fail', 'Skip', 'Info')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Detail,
        [AllowEmptyString()][string]$Fix = '',
        [switch]$BootstrapFix
    )
    return [pscustomobject]@{
        Category     = $Category
        Item         = $Item
        Level        = $script:McpPreflightLevel[$Level]
        Failed       = ($Level -eq 'Fail')
        Detail       = $Detail
        Fix          = $Fix
        BootstrapFix = [bool]$BootstrapFix
    }
}

<#
.SYNOPSIS
    查找命令行工具（排除 Microsoft Store 存根与 WindowsApps 下的发行版）；找不到返回 $null。
#>
function Get-McpPreflightCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and "$($cmd.Source)" -notmatch 'WindowsApps') {
        return $cmd
    }
    return $null
}

<#
.SYNOPSIS
    取运行时工具的版本文本（如 “Python 3.13.14”“v25.9.0”）；不可用返回 $null。
    Python 复用 bootstrap 的启动器探测（每个候选实际运行 --version 验证）。
#>
function Get-McpPreflightToolVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('python', 'node', 'npm', 'curl')][string]$Name)
    switch ($Name) {
        'python' {
            $launcher = Resolve-McpPythonLauncher
            if (-not $launcher) { return $null }
            $pyArgs = @()
            if ($launcher.Count -gt 1) { $pyArgs = $launcher[1..($launcher.Count - 1)] }
            $probe = Invoke-McpNative -FilePath $launcher[0] -ArgumentList @($pyArgs + @('--version'))
            break
        }
        'node' {
            $cmd = Get-McpPreflightCommand -Name 'node'
            if (-not $cmd) { return $null }
            $probe = Invoke-McpNative -FilePath $cmd.Source -ArgumentList @('--version')
            break
        }
        'npm' {
            $cmd = Get-McpPreflightCommand -Name 'npm.cmd'
            if (-not $cmd) { $cmd = Get-McpPreflightCommand -Name 'npm' }
            if (-not $cmd) { return $null }
            $probe = Invoke-McpNative -FilePath $cmd.Source -ArgumentList @('--version')
            break
        }
        'curl' {
            $cmd = Get-McpPreflightCommand -Name 'curl.exe'
            if (-not $cmd) { $cmd = Get-McpPreflightCommand -Name 'curl' }
            if (-not $cmd) { return $null }
            $probe = Invoke-McpNative -FilePath $cmd.Source -ArgumentList @('--version')
            break
        }
    }
    if ($probe.ExitCode -ne 0) { return $null }
    # 只取版本行前两个词（如 “Python 3.13.14”“curl 8.23.0”“v25.9.0”），去掉 curl 冗长的特性列表
    $first = @(("$($probe.Output)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($first.Count -eq 0) { return $null }
    return ((($first[0].Trim() -split '\s+') | Select-Object -First 2) -join ' ')
}

<#
.SYNOPSIS
    可直接执行的 Bootstrap 命令（初始化指定服务的缺失环境）。
#>
function Get-McpPreflightBootstrapCommand {
    [CmdletBinding()]
    param([string]$Code = '')
    $script = Join-Path (Get-McpRepoRoot) 'scripts\bootstrap.ps1'
    $text = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script
    if ($Code) { $text = '{0} -Code {1}' -f $text, $Code }
    return $text
}

<#
.SYNOPSIS
    可直接执行的 GitHub 官方二进制获取命令（需联网）。
#>
function Get-McpPreflightSetupCommand {
    [CmdletBinding()]
    param()
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path (Get-McpRepoRoot) 'mcp-github\setup-github-mcp.ps1'))
}

<#
.SYNOPSIS
    执行登录预检，返回全部检查项（Category / Item / Level / Failed / Detail / Fix / BootstrapFix）。
    只读检查：不创建目录、不改配置、不启动 MCP 进程。
#>
function Get-McpPreflightResult {
    [CmdletBinding()]
    param()

    $items = New-Object System.Collections.Generic.List[object]
    $root = Get-McpRepoRoot
    $services = @(Get-McpServices)

    # ---- 运行时 ----
    $runtimeTools = @(
        @{ Name = 'python'; Label = 'Python（3.12+ 常规发行版）'; UsedBy = '供 Gerrit、Atlassian 的 venv 使用'; Fix = '安装常规发行版 Python 3.12+（python.org），安装时勾选 Add python.exe to PATH，然后重新打开终端（Microsoft Store 版在受限环境不可用）' }
        @{ Name = 'node'; Label = 'Node.js'; UsedBy = '供 GitHub、Jenkins 的启动器使用'; Fix = '安装 Node.js LTS（nodejs.org），安装后重新打开终端' }
        @{ Name = 'npm'; Label = 'npm'; UsedBy = '供 Jenkins 依赖安装（npm ci）使用'; Fix = 'npm 随 Node.js 一并安装：重新安装 Node.js LTS，并确认 npm 在 PATH 中' }
        @{ Name = 'curl'; Label = 'curl.exe'; UsedBy = '供 Gerrit 上游服务的 REST 调用使用'; Fix = 'Windows 10+ 自带 curl.exe：确认 C:\Windows\System32 在 PATH 中；否则从 curl 官方下载并加入 PATH' }
    )
    foreach ($tool in $runtimeTools) {
        $version = Get-McpPreflightToolVersion -Name $tool.Name
        if ($version) {
            $items.Add((New-McpPreflightItem -Category '运行时' -Item $tool.Label -Level Pass -Detail ('{0}（{1}）' -f $version, $tool.UsedBy)))
        }
        else {
            $items.Add((New-McpPreflightItem -Category '运行时' -Item $tool.Label -Level Fail -Detail ('未找到可用的 {0}（{1}）' -f $tool.Label, $tool.UsedBy) -Fix $tool.Fix))
        }
    }

    # ---- 配置状态（就绪判定只读一次；已禁用的服务跳过依赖环境与启动命令检查） ----
    $suitePath = Get-McpSuiteConfigPath
    $cfgStates = @(Test-McpSuiteConfigReady)
    $disabledKeys = @($cfgStates | Where-Object { $_.State -eq '已禁用' } | ForEach-Object { $_.Key })

    # ---- 依赖环境（按注册表） ----
    $depsReady = @{}
    foreach ($svc in $services) {
        if ($disabledKeys -contains $svc.ConfigKey) {
            $depsReady[$svc.Code] = $false
            $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Skip -Detail '已在统一配置中禁用（enabled=false），跳过；需要启用时在 mcpctl 菜单 4 配置向导中把“是否启用”改为“是”，再运行 Bootstrap 菜单 5'))
            continue
        }
        $ready = [bool](Test-McpDepsReady -Service $svc)
        $depsReady[$svc.Code] = $ready
        if ($ready) {
            $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Pass -Detail '依赖环境已就绪'))
            continue
        }
        switch ($svc.Stack) {
            'python' {
                $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Fail -Detail ('虚拟环境未创建：{0}\venv' -f $svc.Id) -Fix ('运行 mcpctl 菜单 5（初始化缺失环境），或执行：{0}' -f (Get-McpPreflightBootstrapCommand -Code $svc.Code)) -BootstrapFix))
            }
            'node' {
                $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Fail -Detail ('依赖目录未创建：{0}\node_modules' -f $svc.Id) -Fix ('运行 mcpctl 菜单 5（初始化缺失环境），或执行：{0}' -f (Get-McpPreflightBootstrapCommand -Code $svc.Code)) -BootstrapFix))
            }
            'binary' {
                $binDesc = '本地二进制'
                if ($svc.BinaryPath) { $binDesc = $svc.BinaryPath }
                $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Fail -Detail ('二进制缺失：{0}' -f $binDesc) -Fix ('联网运行 setup 脚本下载官方二进制（Bootstrap 不代为下载）：{0}' -f (Get-McpPreflightSetupCommand))))
            }
            default {
                $items.Add((New-McpPreflightItem -Category '依赖环境' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Fail -Detail ('未知技术栈：{0}' -f $svc.Stack) -Fix '检查 scripts\mcpctl.config.ps1 中该服务的 Stack 取值（python / node / binary）'))
            }
        }
    }

    # ---- 配置 ----
    $fileState = $cfgStates | Select-Object -First 1
    $fileOk = ($null -ne $fileState -and $fileState.FileExists -and $fileState.FileValid)
    if ($null -eq $fileState -or -not $fileState.FileExists) {
        $items.Add((New-McpPreflightItem -Category '配置' -Item '统一配置文件' -Level Fail -Detail ('文件不存在：{0}' -f $suitePath) -Fix '运行 mcpctl 菜单 4 配置向导（可从模板 mcp.config.sample.json 生成并逐字段录入）；或手动复制模板为 mcp.config.json 后填写'))
    }
    elseif (-not $fileState.FileValid) {
        $items.Add((New-McpPreflightItem -Category '配置' -Item '统一配置文件' -Level Fail -Detail ('{0}' -f $fileState.Reason) -Fix '对照模板 mcp.config.sample.json 修正 JSON 语法（引号、逗号、括号）后重新预检'))
    }
    else {
        $items.Add((New-McpPreflightItem -Category '配置' -Item '统一配置文件' -Level Pass -Detail ('文件可解析：{0}' -f $suitePath)))
    }
    foreach ($st in $cfgStates) {
        $svc = $services | Where-Object { $_.ConfigKey -eq $st.Key } | Select-Object -First 1
        $svcName = '{0}（services.{1}）' -f $svc.DisplayName, $st.Key
        if (-not $fileOk) {
            $items.Add((New-McpPreflightItem -Category '配置' -Item $svcName -Level Skip -Detail '统一配置缺失或无法解析，跳过'))
        }
        elseif ($st.State -eq '已禁用') {
            $items.Add((New-McpPreflightItem -Category '配置' -Item $svcName -Level Skip -Detail '已在统一配置中禁用（enabled=false）'))
        }
        elseif ($st.Ready) {
            $items.Add((New-McpPreflightItem -Category '配置' -Item $svcName -Level Pass -Detail '启用服务的必填项已填写'))
        }
        else {
            $labels = @(@($st.Missing) | ForEach-Object { Get-McpSuiteFieldLabel -Path $_ })
            $missingText = (@($st.Missing) -join '、')
            if ($labels.Count -gt 0) { $missingText = ($labels -join '、') }
            $items.Add((New-McpPreflightItem -Category '配置' -Item $svcName -Level Fail -Detail ('必填项未填写或仍为占位符：{0}' -f $missingText) -Fix ('运行 mcpctl 菜单 4 配置向导，补齐 services.{0} 的上述字段' -f $st.Key)))
        }
    }

    # ---- 启动命令 ----
    foreach ($svc in $services) {
        $svcName = '{0}（{1}）' -f $svc.DisplayName, $svc.Id
        if ($disabledKeys -contains $svc.ConfigKey) {
            $items.Add((New-McpPreflightItem -Category '启动命令' -Item $svcName -Level Skip -Detail '已在统一配置中禁用（enabled=false），跳过'))
            continue
        }
        if (-not (Test-McpStartCommandFilled -Service $svc)) {
            $items.Add((New-McpPreflightItem -Category '启动命令' -Item $svcName -Level Fail -Detail '启动命令未回填（注册表 StartCommand 为空或占位符）' -Fix '检查 scripts\mcpctl.config.ps1 中该服务的 StartCommand'))
        }
        elseif (Test-McpCommandAvailable -Service $svc) {
            $items.Add((New-McpPreflightItem -Category '启动命令' -Item $svcName -Level Pass -Detail ('可执行文件可定位：{0}' -f $svc.StartCommand[0])))
        }
        elseif (-not $depsReady[$svc.Code]) {
            $items.Add((New-McpPreflightItem -Category '启动命令' -Item $svcName -Level Skip -Detail ('可执行文件尚不可定位（{0}）：依赖环境未就绪，先按上方“依赖环境”修复' -f $svc.StartCommand[0])))
        }
        else {
            $items.Add((New-McpPreflightItem -Category '启动命令' -Item $svcName -Level Fail -Detail ('可执行文件不可定位：{0}' -f $svc.StartCommand[0]) -Fix '检查 scripts\mcpctl.config.ps1 中该服务的 StartCommand（仓库相对路径或 PATH 中的命令）'))
        }
    }

    # ---- 提示项（不影响结论） ----
    foreach ($svc in $services) {
        $st = Get-McpServiceStatus -Code $svc.Code | Select-Object -First 1
        if ($st -and $st.State -eq $script:McpServiceState.LeftoverRunning) {
            $items.Add((New-McpPreflightItem -Category '提示' -Item ('{0}（{1}）' -f $svc.DisplayName, $svc.Id) -Level Info -Detail ('发现遗留服务进程（PID {0}）；Host 未拉起时不应存在' -f $st.Pid) -Fix '运行 mcpctl 菜单 2 清理遗留进程'))
        }
    }
    $gerritTmp = Join-Path $root 'var\tmp'
    if (Test-Path -LiteralPath $gerritTmp -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $gerritTmp -Filter 'gerrit-config-*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '^gerrit-config-(\d+)\.json$') {
                $ownerPid = [int]$Matches[1]
                if (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) { continue }
            }
            $items.Add((New-McpPreflightItem -Category '提示' -Item 'Gerrit 临时配置' -Level Info -Detail ('发现遗留临时配置：{0}（属主进程已退出）' -f $f.Name) -Fix '下次 Gerrit 启动时自动清理；也可手动删除该文件（文件内含凭证，请勿外传）'))
        }
    }

    return ,$items.ToArray()
}

<#
.SYNOPSIS
    汇总预检结果：Pass / Fail / Skip / Info 计数。
#>
function Get-McpPreflightSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)
    return [pscustomobject]@{
        Pass = @($Items | Where-Object { $_.Level -eq $script:McpPreflightLevel.Pass }).Count
        Fail = @($Items | Where-Object { $_.Level -eq $script:McpPreflightLevel.Fail }).Count
        Skip = @($Items | Where-Object { $_.Level -eq $script:McpPreflightLevel.Skip }).Count
        Info = @($Items | Where-Object { $_.Level -eq $script:McpPreflightLevel.Info }).Count
    }
}

<#
.SYNOPSIS
    打印预检结果：结果表格 + 逐条下一步。
#>
function Show-McpPreflightResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)

    $Items | Format-Table -AutoSize -Wrap @(
        @{ Label = '类别'; Expression = { $_.Category } },
        @{ Label = '检查项'; Expression = { $_.Item } },
        @{ Label = '结果'; Expression = { $_.Level } },
        @{ Label = '说明'; Expression = { $_.Detail } }
    ) | Out-Host

    $failed = @($Items | Where-Object { $_.Failed })
    if ($failed.Count -gt 0) {
        Write-Host '---------- 下一步（未通过项的修复办法） ----------'
        $no = 0
        foreach ($f in $failed) {
            $no++
            Write-Host ('{0}. [{1}] {2}' -f $no, $f.Item, $f.Detail)
            Write-Host ('   修复：{0}' -f $f.Fix)
        }
    }
    foreach ($i in @($Items | Where-Object { $_.Level -eq $script:McpPreflightLevel.Info })) {
        Write-Host ('[提示] {0}：{1}' -f $i.Item, $i.Detail)
        Write-Host ('   建议：{0}' -f $i.Fix)
    }
    $s = Get-McpPreflightSummary -Items $Items
    Write-Host ('========== 预检汇总：通过 {0} / 未通过 {1} / 跳过 {2} / 提示 {3} ==========' -f $s.Pass, $s.Fail, $s.Skip, $s.Info)
}

<#
.SYNOPSIS
    保存上次预检结果到 logs\preflight-last.json（不含任何配置值）。
#>
function Save-McpPreflightResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)
    $logRoot = Join-Path (Get-McpRepoRoot) (Get-McpGlobalConfig).LogRoot
    if (-not (Test-Path -LiteralPath $logRoot)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
    $path = Join-Path $logRoot $script:McpPreflightLastResultFile
    $s = Get-McpPreflightSummary -Items $Items
    $doc = [ordered]@{
        '生成时间' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        '汇总'     = [ordered]@{ '通过' = $s.Pass; '未通过' = $s.Fail; '跳过' = $s.Skip; '提示' = $s.Info }
        '检查项'   = @($Items | ForEach-Object {
                [ordered]@{ '类别' = $_.Category; '检查项' = $_.Item; '结果' = $_.Level; '说明' = $_.Detail; '修复' = $_.Fix }
            })
    }
    $json = (ConvertTo-McpJsonString -Value $doc) + "`n"
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

<#
.SYNOPSIS
    打印上次保存的预检结果；没有记录时给出提示。
#>
function Show-McpPreflightLastResult {
    [CmdletBinding()]
    param()
    $path = Join-Path (Join-Path (Get-McpRepoRoot) (Get-McpGlobalConfig).LogRoot) $script:McpPreflightLastResultFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host '尚无预检记录：请先执行“立即预检”。'
        return $false
    }
    try {
        $doc = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-Host ('上次预检结果无法读取（{0}）：请重新执行“立即预检”。' -f $path)
        return $false
    }
    Write-Host ('上次预检时间：{0}' -f $doc.'生成时间')
    $levelKey = @{}
    foreach ($k in $script:McpPreflightLevel.Keys) { $levelKey[$script:McpPreflightLevel[$k]] = $k }
    $items = @($doc.'检查项' | ForEach-Object {
            $lv = $_.'结果'
            if (-not $levelKey.ContainsKey("$lv")) { $lv = 'Info' } else { $lv = $levelKey["$lv"] }
            New-McpPreflightItem -Category $_.'类别' -Item $_.'检查项' -Level $lv -Detail $_.'说明' -Fix $_.'修复'
        })
    if ($items.Count -eq 0) {
        $s = $doc.'汇总'
        Write-Host ('汇总：通过 {0} / 未通过 {1} / 跳过 {2} / 提示 {3}' -f $s.'通过', $s.'未通过', $s.'跳过', $s.'提示')
        return $true
    }
    Show-McpPreflightResult -Items $items
    return $true
}

<#
.SYNOPSIS
    环境自愈：对可由 Bootstrap 修复的未通过项执行“初始化缺失环境”。
    -AutoAllowed 表示配置已显式允许（不再询问）；否则交互式确认，输入结束按“否”处理。
    返回：无需自愈 / 已取消 / 已执行。
#>
function Invoke-McpPreflightHeal {
    [CmdletBinding()]
    param([switch]$AutoAllowed)

    $items = Get-McpPreflightResult
    $need = @($items | Where-Object { $_.Failed -and $_.BootstrapFix })
    if ($need.Count -eq 0) {
        Write-Host '没有可通过 Bootstrap 自愈的项目（运行时安装、二进制下载、配置填写需按提示手动处理）。'
        return '无需自愈'
    }
    Write-Host ('可通过 Bootstrap 自愈的项目（{0} 项）：' -f $need.Count)
    foreach ($n in $need) {
        Write-Host ('  - {0}：{1}' -f $n.Item, $n.Detail)
    }
    if (-not $AutoAllowed) {
        if (-not (Read-McpYesNo -Prompt '是否现在执行环境自愈（Bootstrap 初始化缺失环境）？')) {
            Write-Host '已取消环境自愈：未做任何变更。'
            return '已取消'
        }
    }
    Write-Host '开始环境自愈：Bootstrap 初始化缺失环境…'
    try {
        $code = Invoke-McpBootstrap
    }
    catch {
        Write-Host ('环境自愈执行出错：{0}' -f $_.Exception.Message)
        Write-McpOpsLog -Action '环境自愈' -Service '-' -Detail '执行出错'
        return '已执行'
    }
    Write-McpOpsLog -Action '环境自愈' -Service '-' -Detail ('Bootstrap 退出码 {0}' -f $code)
    return '已执行'
}

<#
.SYNOPSIS
    执行一次完整预检：检查 → 打印 → 保存上次结果 → 写操作日志；
    指定 -AllowHeal 且存在可自愈项时，按配置或确认执行自愈并复检。
    返回退出码：0 = 全部通过（或自愈后全部通过），1 = 仍有未通过项。
#>
function Invoke-McpPreflight {
    [CmdletBinding()]
    param([switch]$AllowHeal)

    $items = Get-McpPreflightResult
    Show-McpPreflightResult -Items $items
    $null = Save-McpPreflightResult -Items $items
    $s = Get-McpPreflightSummary -Items $items
    Write-McpOpsLog -Action '登录预检' -Service '-' -Detail ('通过 {0} / 未通过 {1} / 提示 {2}' -f $s.Pass, $s.Fail, $s.Info)

    $healable = @($items | Where-Object { $_.Failed -and $_.BootstrapFix })
    if ($AllowHeal -and $healable.Count -gt 0) {
        $auto = $false
        $cfg = Get-McpGlobalConfig
        if ($cfg.ContainsKey('PreflightAutoBootstrap') -and $cfg['PreflightAutoBootstrap'] -eq $true) { $auto = $true }
        $status = Invoke-McpPreflightHeal -AutoAllowed:$auto
        if ($status -eq '已执行') {
            Write-Host ''
            Write-Host '自愈后复检：'
            $items = Get-McpPreflightResult
            Show-McpPreflightResult -Items $items
            $null = Save-McpPreflightResult -Items $items
            $s = Get-McpPreflightSummary -Items $items
        }
    }
    if ($s.Fail -gt 0) { return 1 }
    return 0
}

# 直接运行时执行；被 dot-source 时不触发
if ($MyInvocation.InvocationName -ne '.') {
    $preflightResult = Invoke-McpPreflight -AllowHeal:($Heal.IsPresent)
    exit ([int]$preflightResult)
}
