#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 服务诊断与遗留进程治理核心函数（M3 / 传输模型整改后）。

.DESCRIPTION
    传输模型（ADR-006，模型一）：MCP stdio 服务由 Host（Cursor / Claude Desktop 等）
    按需拉起；mcpctl 不再后台托管服务进程，也不再重定向服务 stdout 到日志。
    本模块只做四件事：
      - 启动命令诊断：StartCommand 是否回填、可执行文件是否存在、配置是否就绪、
        依赖环境（venv / node_modules / 本地二进制）是否已初始化，输出中文诊断表。
      - MCP 握手探活：以 stdio 短时拉起服务进程，发送 initialize 请求并等待响应，
        超时或异常退出即报告失败；探活进程不写 PID 文件、退出时强制清理进程树。
      - 遗留进程识别与清理：检测残留 PID 文件指向的进程（已消失 / 被复用 / 仍在运行），
        清理动作为二次确认后的 taskkill /F /T 强杀进程树 + 删除 PID 文件（直接强杀，无缓冲退出流程）。
      - 状态表格：代号 / 服务 / 配置就绪 / 依赖环境 / 启动命令已回填 / 遗留进程 / 日志位置。

    用法：
        . (Join-Path $PSScriptRoot 'service-utils.ps1')
        Get-McpServiceStatus                     # 全部服务状态（遗留进程语义）
        Show-McpServiceStatus                    # 表格输出
        Get-McpServiceDiagnostics                # 诊断表
        Invoke-McpHandshakeProbe -Code A         # 单服务握手探活
        Invoke-McpLeftoverCleanup                # 清理遗留进程（交互二次确认）

    操作日志：logs/mcpctl-ops.log，只记事实（服务/动作/结果），不含任何敏感信息。
    本文件不实现 Bootstrap、登录预检与真实服务命令（StartCommand 仍为注册表占位）。
#>

# 加载注册表（服务清单）与统一配置模块（就绪判定 / 读写）
. (Join-Path -Path $PSScriptRoot -ChildPath 'registry.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'suite-config.ps1')

# 遗留进程状态常量（模型一：PID 文件只应来自历史遗留或外部拉起，mcpctl 不再写入）
$script:McpServiceState = @{
    NoPid           = '无遗留进程'
    LeftoverGone    = '遗留（进程已消失，可清理 PID 文件）'
    LeftoverReused  = '遗留（PID 已被其他程序占用，可清理 PID 文件）'
    LeftoverRunning = '遗留（进程仍在运行）'
    Unknown         = '未知'
}

# ---------------------------------------------------------------------------
# 操作日志（只记事实，不含敏感信息）
# ---------------------------------------------------------------------------

function Write-McpOpsLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Service = '-',
        [string]$Detail = ''
    )
    $logRoot = Join-Path (Get-McpRepoRoot) (Get-McpGlobalConfig).LogRoot
    if (-not (Test-Path -LiteralPath $logRoot)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
    $line = ('[{0}] [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action, $Service, $Detail)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText((Join-Path $logRoot 'mcpctl-ops.log'), $line + "`n", $utf8NoBom)
}

# ---------------------------------------------------------------------------
# PID 与进程检测（遗留进程识别的基础）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    读取 PID 文件内容（纯数字）；不存在或非法返回 $null。
#>
function Get-McpServicePid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $pidFile = $Service.PidFileFull
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $raw = (Get-Content -LiteralPath $pidFile -TotalCount 1 -ErrorAction SilentlyContinue)
    $raw = "$raw".Trim()
    if ("$raw" -match '^\d+$') { return [int]$raw }
    return $null
}

<#
.SYNOPSIS
    按 PID 查询进程；不存在返回 $null。
#>
function Get-McpProcessById {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    return Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    判断进程是否属于指定服务（命令行或可执行路径包含服务子目录名）。
#>
function Test-McpProcessOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Service
    )
    $marker = $Service.Id   # 如 mcp-jenkins
    $cmd = "$($Process.CommandLine)"
    $exe = "$($Process.ExecutablePath)"
    return ($cmd -like "*$marker*" -or $exe -like "*$marker*")
}

<#
.SYNOPSIS
    计算单个服务遗留进程状态。

.DESCRIPTION
    模型一：mcpctl 不再拉起服务，PID 文件只可能来自：
      - 历史版本 mcpctl 托管残留；
      - 或用户手工记录。
    判定规则：
      - 无 PID 文件 → NoPid；
      - PID 文件存在但进程不存在 → LeftoverGone（可清理 PID 文件）；
      - 进程存在但命令行/路径不含服务目录 → LeftoverReused（PID 被无关进程复用，
        只清理 PID 文件，绝不误杀）；
      - 进程存在且属于本服务 → LeftoverRunning（Host 未拉起时不应存在，
        视为遗留，可由“清理遗留进程”入口二次确认后强杀）。
#>
function Get-McpServiceStatus {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    foreach ($svc in $services) {
        $svcPid = Get-McpServicePid -Service $svc
        $state = $script:McpServiceState.NoPid
        $proc = $null
        if ($svcPid) {
            $proc = Get-McpProcessById -ProcessId $svcPid
            if (-not $proc) {
                $state = $script:McpServiceState.LeftoverGone
            }
            elseif (Test-McpProcessOwnership -Process $proc -Service $svc) {
                $state = $script:McpServiceState.LeftoverRunning
            }
            else {
                $state = $script:McpServiceState.LeftoverReused
            }
        }
        [pscustomobject]@{
            Code        = $svc.Code
            Id          = $svc.Id
            DisplayName = $svc.DisplayName
            State       = $state
            Pid         = $svcPid
            LogFile     = $svc.LogFile
            LogExists   = (Test-Path -LiteralPath $svc.LogFileFull)
            PidFile     = $svc.PidFile
            Process     = $proc
        }
    }
}

<#
.SYNOPSIS
    清理失效 PID 文件（进程已消失或 PID 被复用时删除 PID 文件；不触碰仍在运行的进程）。
#>
function Remove-McpStalePidFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $st = Get-McpServiceStatus -Code $Service.Code | Select-Object -First 1
    if ($st.State -in @($script:McpServiceState.LeftoverGone, $script:McpServiceState.LeftoverReused) -and
        (Test-Path -LiteralPath $Service.PidFileFull)) {
        Remove-Item -LiteralPath $Service.PidFileFull -Force
        Write-Host ("已清理 PID 文件：{0}（{1}）" -f $Service.PidFile, $st.State)
        Write-McpOpsLog -Action '清理PID' -Service $Service.Id -Detail $st.State
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# 启动命令诊断
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    判断服务的启动命令是否已回填注册表（非空数组且首元素非占位符）。
#>
function Test-McpStartCommandFilled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $cmd = $Service.StartCommand
    if (-not $cmd -or $cmd.Count -lt 1) { return $false }
    $exe = "$($cmd[0])".Trim()
    if (-not $exe) { return $false }
    if ($exe -match '^<.*>$') { return $false }   # <待 Mx 回填> 形式占位
    return $true
}

<#
.SYNOPSIS
    判断启动命令的可执行文件是否可定位（绝对路径存在，或可在 PATH 中找到）。
#>
function Test-McpCommandAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    if (-not (Test-McpStartCommandFilled -Service $Service)) { return $false }
    $exe = "$($Service.StartCommand[0])".Trim()
    if ([IO.Path]::IsPathRooted($exe)) {
        return (Test-Path -LiteralPath $exe -PathType Leaf)
    }
    return ($null -ne (Get-Command $exe -ErrorAction SilentlyContinue))
}

<#
.SYNOPSIS
    判断依赖环境是否已初始化（python→venv；node→node_modules；binary→BinaryPath 或 <服务Id>.exe）。
#>
function Test-McpDepsReady {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $svcDir = Join-Path (Get-McpRepoRoot) $Service.Id
    switch ($Service.Stack) {
        'python' {
            return (Test-Path -LiteralPath (Join-Path $svcDir 'venv\Scripts\python.exe') -PathType Leaf)
        }
        'node' {
            $nm = Join-Path $svcDir 'node_modules'
            return ((Test-Path -LiteralPath $nm -PathType Container) -and
                    (@(Get-ChildItem -LiteralPath $nm -ErrorAction SilentlyContinue).Count -gt 0))
        }
        'binary' {
            if ($Service.BinaryPath) {
                return (Test-Path -LiteralPath (Join-Path (Get-McpRepoRoot) $Service.BinaryPath) -PathType Leaf)
            }
            return (Test-Path -LiteralPath (Join-Path $svcDir ("{0}.exe" -f $Service.Id)) -PathType Leaf)
        }
        default { return $false }
    }
}

<#
.SYNOPSIS
    生成全部（或指定）服务的启动命令诊断表。

.DESCRIPTION
    每服务输出：配置就绪 / 依赖环境 / 启动命令已回填 / 可执行文件可定位。
    配置就绪取自统一配置 mcp.config.json（services.<ConfigKey> 段）；已在统一配置中
    禁用（enabled=false）的服务单列状态“已禁用”。命令未回填时给出中文提示而非抛异常。
#>
function Get-McpServiceDiagnostics {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    $suiteReady = @{}
    foreach ($r in (Test-McpSuiteConfigReady)) { $suiteReady[$r.Key] = $r }
    foreach ($svc in $services) {
        $ready = $suiteReady[$svc.ConfigKey]
        $cmdFilled = Test-McpStartCommandFilled -Service $svc
        $cmdExists = if ($cmdFilled) { Test-McpCommandAvailable -Service $svc } else { $false }
        $depsReady = Test-McpDepsReady -Service $svc

        $hint = ''
        if ($ready.State -eq '已禁用') {
            $hint = '已在统一配置中禁用（enabled=false）：不参与握手、导出与批量启动'
        }
        elseif (-not $ready.FileExists) {
            $hint = '统一配置文件不存在：请运行配置向导（菜单 4），从模板生成 mcp.config.json 并逐字段录入'
        }
        elseif (-not $ready.FileValid) {
            $hint = $ready.Reason
        }
        elseif (-not $ready.Ready) {
            $hint = '配置未就绪（' + $ready.Reason
            if (@($ready.Missing).Count -gt 0) { $hint += '，缺失：' + (@($ready.Missing) -join ', ') }
            $hint += '），请运行配置向导（菜单 4）补齐，或直接编辑 mcp.config.json'
        }
        elseif (-not $cmdFilled) {
            $hint = '启动命令未配置：请检查 scripts/mcpctl.config.ps1 中该服务的 StartCommand（缺失时请参照已接入服务补全，随后运行 Bootstrap 准备依赖环境）'
        }
        elseif (-not $cmdExists) {
            $hint = '可执行文件不存在或不在 PATH（检查安装与注册表命令首段）'
        }
        elseif (-not $depsReady) {
            $hint = '依赖环境未初始化，请先运行 Bootstrap'
        }
        else {
            $hint = '可由 Host 按需 stdio 拉起（可用“握手探活”验证）'
        }

        [pscustomobject]@{
            Code           = $svc.Code
            Id             = $svc.Id
            DisplayName    = $svc.DisplayName
            ConfigReady    = $ready.Ready
            ConfigEnabled  = $ready.Enabled
            ConfigState    = $ready.State
            DepsReady      = $depsReady
            CommandFilled  = $cmdFilled
            CommandExists  = $cmdExists
            MissingFields  = (@($ready.Missing) -join ', ')
            Hint           = $hint
        }
    }
}

<#
.SYNOPSIS
    以表格输出诊断结果。
#>
function Show-McpServiceDiagnostics {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    Get-McpServiceDiagnostics @PSBoundParameters | ForEach-Object {
        [pscustomobject]@{
            '代号'             = $_.Code
            '服务'             = $_.DisplayName
            '配置就绪'         = if ($_.ConfigState -eq '已禁用') { '已禁用' } elseif ($_.ConfigReady) { '是' } else { '否' }
            '依赖环境'         = if ($_.DepsReady) { '已就绪' } else { '未初始化' }
            '启动命令已回填'   = if ($_.CommandFilled) { '是' } else { '否' }
            '可执行文件'       = if ($_.CommandExists) { '可定位' } else { '不可定位' }
            '提示'             = $_.Hint
        }
    } | Format-Table -AutoSize -Wrap | Out-Host
    Write-McpOpsLog -Action '诊断' -Service '-' -Detail 'ALL'
}

# ---------------------------------------------------------------------------
# MCP 握手探活（stdio 短时拉起，不写 PID、不托管）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    对单个服务执行 MCP stdio 握手探活。

.DESCRIPTION
    以短时进程按注册表 StartCommand 拉起服务，发送 JSON-RPC initialize 请求，
    等待响应（默认 8 秒超时）。握手成功后先关闭标准输入让服务自行退出（启动器可借机
    清理运行期临时文件），超时未退出再强制结束进程树（taskkill /F /T）。
    不写 PID 文件、不重定向日志。探活失败只影响本服务，不影响其他服务。

.PARAMETER TimeoutSeconds
    等待 initialize 响应的超时秒数（默认 8）。
#>
function Invoke-McpHandshakeProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [int]$TimeoutSeconds = 8,
        [switch]$Quiet
    )
    $head = if ($Quiet) { { param($m) } } else { { param($m) Write-Host $m } }

    if (-not (Test-McpStartCommandFilled -Service $Service)) {
        & $head ("[探活跳过] {0}：启动命令未配置，请检查 scripts/mcpctl.config.ps1 中该服务的 StartCommand。" -f $Service.DisplayName)
        Write-McpOpsLog -Action '探活跳过' -Service $Service.Id -Detail 'StartCommand占位'
        return [pscustomobject]@{ Code = $Service.Code; Probed = $false; Ok = $false; Reason = 'no-command' }
    }
    if (-not (Test-McpCommandAvailable -Service $Service)) {
        & $head ("[探活失败] {0}：可执行文件不存在或不在 PATH。" -f $Service.DisplayName)
        Write-McpOpsLog -Action '探活失败' -Service $Service.Id -Detail '可执行文件不可定位'
        return [pscustomobject]@{ Code = $Service.Code; Probed = $true; Ok = $false; Reason = 'exe-missing' }
    }

    $exe = "$($Service.StartCommand[0])".Trim()
    $restArgs = @()
    if ($Service.StartCommand.Count -gt 1) { $restArgs = @($Service.StartCommand[1..($Service.StartCommand.Count - 1)]) }
    # 简单引号包装（参数含空格场景；M5–M8 回填时避免在参数中内嵌双引号）
    $argLine = ($restArgs | ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } }) -join ' '

    $initJson = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcpctl-probe","version":"0.1.0"}}}'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = (Get-McpRepoRoot)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # 服务端（含各启动器）统一按 UTF-8 输出
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    # 不使用 DataReceivedEventHandler 事件回调：回调在线程池线程上执行，该线程没有可用的运行空间，
    # PowerShell 会在收到输出的瞬间崩溃（5.1 与 7 均如此）。改为异步读取 + 轮询，两个引擎行为一致。
    $sbOut = New-Object System.Text.StringBuilder
    $sbErr = New-Object System.Text.StringBuilder
    $outTask = $null
    $errTask = $null
    # 逐行取回已到达的输出（读到一行就立刻开始读下一行，避免管道缓冲区写满）
    $drainOut = {
        while ($outTask -and $outTask.IsCompleted) {
            $line = $outTask.Result
            if ($null -eq $line) { $outTask = $null; break }
            [void]$sbOut.AppendLine($line)
            $outTask = $proc.StandardOutput.ReadLineAsync()
        }
    }
    $drainErr = {
        while ($errTask -and $errTask.IsCompleted) {
            $line = $errTask.Result
            if ($null -eq $line) { $errTask = $null; break }
            [void]$sbErr.AppendLine($line)
            $errTask = $proc.StandardError.ReadLineAsync()
        }
    }

    $proc = $null
    $responded = $false
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadLineAsync()
        $errTask = $proc.StandardError.ReadLineAsync()
        $proc.StandardInput.WriteLine($initJson)
        $proc.StandardInput.Flush()

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            . $drainOut
            . $drainErr
            if ($sbOut.ToString() -match '"jsonrpc"') { $responded = $true; break }
            if ($proc.HasExited) {
                # 进程已退出：稍等残余输出到达后再取回一次
                Start-Sleep -Milliseconds 200
                . $drainOut
                . $drainErr
                break
            }
            Start-Sleep -Milliseconds 150
        }

        if ($responded) {
            # 握手成功后先优雅收尾：关闭标准输入（MCP stdio 服务在输入流结束后自行退出，
            # 启动器可借机清理运行期临时文件）；超时未退出再由 finally 强制结束进程树
            try { $proc.StandardInput.Close() } catch { }
            $proc.WaitForExit(3000) | Out-Null
        }

        $stderrTail = ''
        if (-not $responded) { $stderrTail = (@($sbErr.ToString() -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' ' }
        $exitNote = if ($proc.HasExited) { ("进程已退出（code {0}）" -f $proc.ExitCode) } else { '进程仍在运行' }
    }
    catch {
        if ($proc -and -not $proc.HasExited) { Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }
        & $head ("[探活失败] {0}：启动异常（{1}）。" -f $Service.DisplayName, $_.Exception.Message)
        Write-McpOpsLog -Action '探活失败' -Service $Service.Id -Detail $_.Exception.Message
        return [pscustomobject]@{ Code = $Service.Code; Probed = $true; Ok = $false; Reason = 'error' }
    }
    finally {
        # 无论结果如何都强制清理探活进程树（探活进程绝不遗留）
        if ($proc -and -not $proc.HasExited) {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            $proc.WaitForExit(3000) | Out-Null
        }
        if ($proc) { $proc.Dispose() }
    }

    if ($responded) {
        & $head ("[探活通过] {0}：stdio 握手成功（initialize 已响应）。" -f $Service.DisplayName)
        Write-McpOpsLog -Action '探活通过' -Service $Service.Id -Detail 'initialize响应'
        return [pscustomobject]@{ Code = $Service.Code; Probed = $true; Ok = $true; Reason = 'ok' }
    }
    & $head ("[探活失败] {0}：{1}，未见 initialize 响应。{2}" -f $Service.DisplayName, $exitNote, $(if ($stderrTail) { "stderr 摘要：$stderrTail" }))
    Write-McpOpsLog -Action '探活失败' -Service $Service.Id -Detail $exitNote
    return [pscustomobject]@{ Code = $Service.Code; Probed = $true; Ok = $false; Reason = 'no-response' }
}

# ---------------------------------------------------------------------------
# 遗留进程清理（二次确认；taskkill /F /T 强杀进程树）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    清理单个服务的遗留进程（二次确认后 taskkill /F /T 强杀进程树并删除 PID 文件）。

.DESCRIPTION
    仅处理“遗留进程”三种状态；无 PID 文件时直接提示无需清理。
    LeftoverReused（PID 被无关程序占用）只删除 PID 文件，绝不终止他人进程。
#>
function Invoke-McpLeftoverCleanupSingle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [switch]$Quiet
    )
    $head = if ($Quiet) { { param($m) } } else { { param($m) Write-Host $m } }
    $st = Get-McpServiceStatus -Code $Service.Code | Select-Object -First 1

    if ($st.State -eq $script:McpServiceState.NoPid) {
        & $head ("[清理] {0}：无遗留进程。" -f $Service.DisplayName)
        return [pscustomobject]@{ Code = $Service.Code; Cleaned = $false; Reason = 'nothing' }
    }

    if ($st.State -in @($script:McpServiceState.LeftoverGone, $script:McpServiceState.LeftoverReused)) {
        Remove-McpStalePidFile -Service $Service | Out-Null
        & $head ("[清理] {0}：已删除失效 PID 文件（{1}）。" -f $Service.DisplayName, $st.State)
        return [pscustomobject]@{ Code = $Service.Code; Cleaned = $true; Reason = 'pid-file-removed' }
    }

    # LeftoverRunning：进程仍在运行 —— 二次确认后强杀进程树
    $svcPid = $st.Pid
    $ans = if ($Quiet) { $true } else {
        (Read-Host -Prompt ("确认强制结束 {0} 的遗留进程 PID {1} 及其子进程？（taskkill /F /T 直接强杀进程树）[y/N]" -f $Service.DisplayName, $svcPid)) -match '^(y|Y|是)$'
    }
    if (-not $ans) {
        & $head ("[清理] {0}：已取消，保留进程运行（PID {1}）。" -f $Service.DisplayName, $svcPid)
        Write-McpOpsLog -Action '清理取消' -Service $Service.Id -Detail ("PID={0} 保留" -f $svcPid)
        return [pscustomobject]@{ Code = $Service.Code; Cleaned = $false; Reason = 'kept-by-user' }
    }

    Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $svcPid /T /F" -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds((Get-McpGlobalConfig).GracefulStopTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-McpProcessById -ProcessId $svcPid)) { break }
        Start-Sleep -Seconds (Get-McpGlobalConfig).StopPollingIntervalSeconds
    }
    if (Get-McpProcessById -ProcessId $svcPid) {
        & $head ("[清理失败] {0}：强杀仍失败（PID {1}），请人工处理。" -f $Service.DisplayName, $svcPid)
        Write-McpOpsLog -Action '清理失败' -Service $Service.Id -Detail ("PID={0}" -f $svcPid)
        return [pscustomobject]@{ Code = $Service.Code; Cleaned = $false; Reason = 'force-failed' }
    }
    if (Test-Path -LiteralPath $Service.PidFileFull) { Remove-Item -LiteralPath $Service.PidFileFull -Force }
    & $head ("[清理] {0}：遗留进程已强杀（PID {1}），PID 文件已删除。" -f $Service.DisplayName, $svcPid)
    Write-McpOpsLog -Action '清理遗留进程' -Service $Service.Id -Detail ("PID={0} 强杀进程树" -f $svcPid)
    return [pscustomobject]@{ Code = $Service.Code; Cleaned = $true; Reason = 'force-killed' }
}

<#
.SYNOPSIS
    批量清理遗留进程（省略 Code 时遍历全部服务；单服务失败不阻断其余）。
#>
function Invoke-McpLeftoverCleanup {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Code,
        [switch]$Quiet
    )
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    $results = @()
    foreach ($svc in $services) {
        $results += Invoke-McpLeftoverCleanupSingle -Service $svc -Quiet:$Quiet
    }
    return $results
}

# ---------------------------------------------------------------------------
# 状态表格（新列：配置就绪 / 依赖环境 / 启动命令已回填 / 遗留进程 / 日志位置）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    以表格输出全部服务状态（传输模型整改后的新列集）。
#>
function Show-McpServiceStatus {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $diags = @{}
    Get-McpServiceDiagnostics @PSBoundParameters | ForEach-Object { $diags[$_.Code] = $_ }
    Get-McpServiceStatus @PSBoundParameters | ForEach-Object {
        $d = $diags[$_.Code]
        [pscustomobject]@{
            '代号'           = $_.Code
            '服务'           = $_.DisplayName
            '配置就绪'       = if ($d -and $d.ConfigState -eq '已禁用') { '已禁用' } elseif ($d -and $d.ConfigReady) { '是' } else { '否' }
            '依赖环境'       = if ($d -and $d.DepsReady) { '已就绪' } else { '未初始化' }
            '启动命令已回填' = if ($d -and $d.CommandFilled) { '是' } else { '否' }
            '遗留进程'       = $_.State
            '日志位置'       = $_.LogFile
        }
    } | Format-Table -AutoSize -Wrap | Out-Host
    Write-McpOpsLog -Action '查看状态' -Service '-' -Detail 'ALL'
}
