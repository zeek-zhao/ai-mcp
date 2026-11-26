#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 总控主菜单（传输模型整改后：Host 拉起 stdio，见 ADR-006）。

.DESCRIPTION
    全中文交互菜单。模型一：mcpctl 不再后台托管服务进程，只做治理：
      1. 服务诊断与自检（启动命令 / 配置 / 依赖环境 + 可选 MCP 握手探活）
      2. 清理遗留进程（二次确认，taskkill /F /T 强杀进程树）
      3. 查看服务状态（配置就绪 / 依赖环境 / 启动命令 / 遗留进程 / 日志位置）
      4. 配置向导（统一配置 mcp.config.json：逐字段录入、从旧配置导入、连通性测试）
      5. 初始化运行环境 Bootstrap（M4：检查 / 初始化 / 重建）
      6. 导出 Host 配置（stdio 配置片段写入仓库外本地文件，不含明文凭证；条目带 env.MCP_SUITE_CONFIG，已禁用的服务不导出）
      7. 登录预检与环境自愈（检查运行时 / 依赖环境 / 配置 / 启动命令并给出修复命令；自愈需确认或配置允许）
      8. 生成 Magpie 路由配置（按注册表生成本机 gateway.routes.json，不入库；生成后自检并打印登记命令）
    MCP 服务本体由 Host（Cursor / Claude Desktop 等）按需 stdio 拉起，
    mcpctl 不启动、不停止、不托管服务进程。

    运行：pwsh / powershell 下执行 scripts\mcpctl.ps1。
#>

# 加载核心库（注册表 / 统一配置 / 配置向导 / 诊断与遗留进程治理 / Bootstrap / 登录预检 / 网关路由生成）
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\service-utils.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\config-wizard.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'bootstrap.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'autostart.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\gateway-routes.ps1')

function Show-McpMenu {
    Clear-Host
    Write-Host '=============================================='
    Write-Host '        MCP 服务总控（mcpctl）'
    Write-Host ('        仓库：' + (Get-McpRepoRoot))
    Write-Host ('        [根路径] ' + (Get-McpRepoRootSourceText))
    Write-Host '  模型：服务由 Host 按需 stdio 拉起，本工具只做治理'
    Write-Host '=============================================='
    Write-Host '  [1] 服务诊断与自检（含握手探活入口）'
    Write-Host '  [2] 清理遗留进程（二次确认强杀）'
    Write-Host '  [3] 查看服务状态'
    Write-Host '  [4] 配置向导（统一配置 mcp.config.json）'
    Write-Host '  [5] 初始化运行环境（Bootstrap：检查 / 初始化 / 重建）'
    Write-Host '  [6] 导出 Host 配置（stdio 片段，本地文件）'
    Write-Host '  [7] 登录预检与环境自愈（不拉起 MCP 进程）'
    Write-Host '  [8] 生成 Magpie 路由配置（本地 gateway.routes.json，不入库）'
    Write-Host '  [0] 退出'
    Write-Host '----------------------------------------------'
}

<#
.SYNOPSIS
    导出 Host stdio 配置片段到本地文件（默认仓库外，不含明文凭证）。

.DESCRIPTION
    每个服务条目包含 command / args / env / note：
      - command、args：已归一化的本机绝对路径启动命令（服务由 Host 按需 stdio 拉起）；
      - env.MCP_SUITE_CONFIG：统一配置文件（mcp.config.json）的本机绝对路径，启动器据此读取配置；
      - note：配置来源与就绪状态的中文说明。
    在统一配置中禁用（enabled=false）的服务不导出。导出文件只含配置文件路径，不含任何凭证。
#>
function Invoke-McpHostConfigExport {
    $suitePath = Get-McpSuiteConfigPath
    $defaultPath = Join-Path $env:USERPROFILE 'mcp-host-config.json'
    $target = Read-Host ("输出文件路径（默认：{0}）" -f $defaultPath)
    if ($null -eq $target) {
        # 标准输入已结束（Read-Host 返回 $null）：直接返回，避免误用默认路径写出文件
        Write-Host '输入已关闭，未导出。'
        return
    }
    if (-not $target) { $target = $defaultPath }

    $servers = [ordered]@{}
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($svc in (Get-McpServices)) {
        $ready = Test-McpSuiteConfigReady -Key $svc.ConfigKey | Select-Object -First 1
        if ($ready.State -eq '已禁用') {
            # enabled=false：不进导出结果（与状态表、批量启动的口径一致）
            $skipped.Add($svc.DisplayName)
            continue
        }
        $entry = [ordered]@{}
        if ((Test-McpStartCommandFilled -Service $svc) -and (Test-McpCommandAvailable -Service $svc)) {
            # StartCommand 已在 Get-McpServices 出口归一化（仓库内相对路径→绝对路径，PATH 命令保留原名）
            $entry['command'] = "$($svc.StartCommand[0])"
            $argsArr = @()
            if ($svc.StartCommand.Count -gt 1) { $argsArr = @($svc.StartCommand[1..($svc.StartCommand.Count - 1)]) }
            $entry['args'] = $argsArr
        }
        else {
            $entry['command'] = "<未回填>"
            $entry['args'] = @()
        }
        # 统一配置路径经环境变量传给启动器；凭证只保存在统一配置文件中，导出文件不写任何明文凭证
        $entry['env'] = [ordered]@{ MCP_SUITE_CONFIG = $suitePath }
        $stateText = if ($ready.Ready) { '已就绪' } else { '未就绪，请先运行配置向导（菜单 4）' }
        $entry['note'] = ("配置来源：{0}（{1}；含凭证，不入库）" -f $suitePath, $stateText)
        $servers[$svc.Id] = $entry
    }
    if ($skipped.Count -gt 0) {
        Write-Host ("已跳过（在统一配置中禁用，enabled=false）：{0}" -f ($skipped -join '、'))
    }
    if ($servers.Count -eq 0) {
        Write-Host '没有可导出的服务：全部服务均已在统一配置中禁用。'
        return
    }

    $doc = [ordered]@{
        '_说明' = 'Host（Cursor / Claude Desktop 等）stdio 拉起配置片段；服务由 Host 按需启动，mcpctl 不托管进程。每个条目的 env.MCP_SUITE_CONFIG 指向统一配置文件（含凭证，不入库）。'
        'mcpServers' = $servers
    }
    # 未就绪/未回填服务的中文告警汇总
    $notReady = @(Get-McpServiceDiagnostics | Where-Object { -not ($_.CommandFilled -and $_.CommandExists) })
    if ($notReady.Count -gt 0) {
        Write-Host ("告警：以下服务启动命令不可定位或未配置：{0}" -f (($notReady | ForEach-Object { $_.Id }) -join '、'))
        Write-Host "下一步：检查 scripts/mcpctl.config.ps1 的 StartCommand；Python/Node 服务先运行 Bootstrap；GitHub 服务先运行 mcp-github/setup-github-mcp.ps1。"
    }
    # 用统一配置模块的序列化：2 空格缩进、保持键顺序、中文原样（PowerShell 5.1 与 7 输出一致）
    # 注意：-Depth 是该函数递归时使用的“当前缩进层级”，顶层调用不要传
    $json = (ConvertTo-McpJsonString -Value $doc) + "`n"
    $targetDir = Split-Path -Parent $target
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($target, $json, $utf8NoBom)
    Write-Host ("已导出 Host 配置片段：{0}（仓库外文件，不含明文凭证）" -f $target)
    Write-Host "注意：command/args 与 env.MCP_SUITE_CONFIG 均为本机绝对路径；迁移到其他机器后需重新运行本导出。"
    Write-McpOpsLog -Action '导出Host配置' -Service '-' -Detail ("导出 {0} 个服务、跳过已禁用 {1} 个 → {2}" -f $servers.Count, $skipped.Count, $target)
}

<#
.SYNOPSIS
    生成 Magpie 网关路由配置 gateway.routes.json（T-ENV-02）。

.DESCRIPTION
    按注册表 StartCommand 生成本机路由（含本机绝对路径，已被 .gitignore 排除，不入库），生成后自检，
    并打印登记到 Magpie 的命令。文件已存在时先报告它与注册表的差异，再选择 覆盖 / 另存为带时间戳的副本 / 取消。
#>
function Invoke-McpGatewayRoutesExport {
    $root = Get-McpRepoRoot
    $target = Join-Path $root $script:McpGatewayFileName
    try {
        $routes = New-McpGatewayRoutes -Root $root
    }
    catch {
        Write-Host ('生成网关路由失败：' + $_.Exception.Message)
        return 1
    }
    $problems = @(Test-McpGatewayRoutes -Routes $routes -Root $root)
    if ($problems.Count -gt 0) {
        Write-Host '生成结果自检未通过，未写入任何文件：'
        foreach ($p in $problems) { Write-Host ('  - ' + $p) }
        return 1
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $diff = @(Compare-McpGatewayRoutesFile -Path $target -Root $root)
        if ($diff.Count -eq 0) {
            Write-Host ('现有 {0} 与注册表一致。' -f $script:McpGatewayFileName)
        }
        else {
            Write-Host ('现有 {0} 与注册表不一致（重新生成即可修正）：' -f $script:McpGatewayFileName)
            foreach ($d in $diff) { Write-Host ('  - ' + $d) }
        }
        Write-Host '  [1] 覆盖  [2] 另存为带时间戳的副本（gateway.routes.<时间戳>.json）  [3] 取消'
        $mode = Read-Host '请选择操作 [1-3]'
        if ($null -eq $mode) { Write-Host '输入已关闭，未写入。'; return 1 }
        switch ($mode.Trim()) {
            '1' { }
            '2' { $target = Join-Path $root ('gateway.routes.{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
            default { Write-Host '已取消。'; return 1 }
        }
    }
    try {
        $null = Save-McpGatewayRoutes -Routes $routes -Path $target
    }
    catch {
        Write-Host ('写入网关路由失败：' + $_.Exception.Message)
        return 1
    }
    Write-Host ''
    Write-Host ('已生成 Magpie 路由配置：{0}' -f $target)
    Write-Host '  含本机绝对路径，已被 .gitignore 排除，不得提交；凭证不在本文件，仍只在统一配置 mcp.config.json。'
    Write-Host '登记到 Magpie（在终端逐条执行；--local 表示仅本机）：'
    foreach ($line in (Get-McpGatewayRegisterCommands -Routes $routes)) { Write-Host ('  ' + $line) }
    Write-Host '分派给 agent（按需替换 agent 列表）：magpie library mcp agents <服务名> <agent1,agent2…>'
    Write-Host '  若提示 the library already has a server called …：该服务已在库中；要按新生成的内容覆盖，先执行 magpie library mcp rm <服务名>，再执行上面的登记命令（重新登记后需重新分派 agent）。'
    Write-Host '在界面手工录入时按下面字段对照（与生成的文件内容相同）：'
    foreach ($name in $routes['mcpServers'].Keys) {
        $entry = $routes['mcpServers'][$name]
        Write-Host ('  {0}：传输=stdio；命令={1}；参数={2}；环境变量 {3}={4}' -f $name, $entry['command'], (@($entry['args']) -join ' '), $script:McpGatewayConfigEnvName, $entry['env'][$script:McpGatewayConfigEnvName])
    }
    Write-McpOpsLog -Action '生成Magpie路由' -Service '-' -Detail ('写入 {0}（{1} 个服务）' -f (Split-Path -Leaf $target), $routes['mcpServers'].Count)
    return 0
}

function Invoke-McpctlMenu {
    while ($true) {
        Show-McpMenu
        $choice = Read-Host '请选择操作 [0-8]'
        if ($null -eq $choice) {
            # 标准输入已结束（例如被脚本调用且输入耗尽）：Read-Host 返回 $null，直接退出，避免菜单空转
            Write-Host '输入已关闭，退出 mcpctl。'
            return
        }
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
                if ($null -eq $scope) { Write-Host '输入已关闭，未执行清理。' }
                elseif ($scope -eq '2') {
                    $c = Read-Host '请输入服务代号'
                    if ($null -eq $c) { Write-Host '输入已关闭，未执行清理。' }
                    else { Invoke-McpLeftoverCleanup -Code $c | Out-Null }
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
                if ($null -eq $mode) { Write-Host '输入已关闭，未执行 Bootstrap。' }
                else {
                    switch ($mode) {
                        '1' { Invoke-McpBootstrap -Check | Out-Null }
                        '3' { Invoke-McpBootstrap -Rebuild | Out-Null }
                        default { Invoke-McpBootstrap | Out-Null }
                    }
                }
            }
            '6' {
                Invoke-McpHostConfigExport
            }
            '7' {
                Write-Host '登录预检与环境自愈：预检不拉起任何 MCP 进程，也不改动系统；自愈仅在确认（或配置 PreflightAutoBootstrap = $true）后执行。'
                Write-Host '  [1] 立即预检    [2] 查看上次预检结果    [3] 环境自愈（Bootstrap 初始化缺失环境）'
                $mode = Read-Host '请选择操作 [1-3]，直接回车取消'
                if ($null -eq $mode) { Write-Host '输入已关闭，未执行预检。' }
                else {
                    switch ($mode.Trim()) {
                        '1' { $null = Invoke-McpPreflight -AllowHeal }
                        '2' { $null = Show-McpPreflightLastResult }
                        '3' {
                            $auto = $false
                            $cfg = Get-McpGlobalConfig
                            if ($cfg.ContainsKey('PreflightAutoBootstrap') -and $cfg['PreflightAutoBootstrap'] -eq $true) { $auto = $true }
                            if ((Invoke-McpPreflightHeal -AutoAllowed:$auto) -eq '已执行') {
                                Write-Host ''
                                Write-Host '自愈后复检：'
                                $null = Invoke-McpPreflight
                            }
                        }
                        default { Write-Host '已取消。' }
                    }
                }
            }
            '8' {
                $null = Invoke-McpGatewayRoutesExport
            }
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
    # 环境变量 MCP_SUITE_ROOT 已设置但无效：不回退到脚本位置，打印原因后退出（T-ENV-01）
    $mcpRootIssue = Get-McpRepoRootIssue
    if ($mcpRootIssue) {
        Write-Host '=============================================='
        Write-Host '        MCP 服务总控（mcpctl）'
        Write-Host '=============================================='
        Write-Host '  [根路径] 环境变量 MCP_SUITE_ROOT 无效，未回退到脚本位置：'
        Write-Host ('    ' + $mcpRootIssue)
        Write-Host '    说明：setx 只对之后新开的窗口生效；当前窗口可先执行 Remove-Item Env:\MCP_SUITE_ROOT'
        exit 1
    }
    Invoke-McpctlMenu
}
