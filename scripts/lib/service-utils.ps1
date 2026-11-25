#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 启停与状态核心函数（M3）。

.DESCRIPTION
    提供服务状态检测、批量启动、优雅停止、PID 管理与操作日志：
      - 状态检测：读取 PID 文件、校验进程存在、识别僵尸 PID（进程已消失或 PID 被无关进程复用）。
      - 启动：批量只启动“已就绪”的服务；未配置跳过并中文提示；单服务异常不阻断其余；
        成功后写入 PID 文件并重定向日志。
      - 优雅停止：通知退出 → 按全局超时轮询等待 → 超时二次确认 → 强制结束；成功后清理 PID。
      - 状态表格输出：服务名、状态、PID、是否就绪、日志位置。
      - 操作日志：logs/mcpctl-ops.log，只记事实（服务/动作/PID/结果），不含任何敏感信息。

    用法：
        . (Join-Path $PSScriptRoot 'service-utils.ps1')
        Get-McpServiceStatus            # 全部服务状态
        Start-McpServices               # 批量启动就绪服务
        Stop-McpServices -Code C        # 停止单个服务
        Show-McpServiceStatus           # 表格输出

.NOTES
    说明：Windows 下“通知退出”以 taskkill（不带 /F）实现，对无窗口进程通常无效；
    M5–M8 各服务接入时可按技术栈定制真正的优雅退出（如 Jenkins HTTP 关闭接口）。
    本文件不实现 Bootstrap、常驻管理与真实服务命令（StartCommand 仍为注册表占位）。
#>

# 加载注册表（服务清单、全局超时参数）与配置向导的就绪判定
. (Join-Path -Path $PSScriptRoot -ChildPath 'registry.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'config-wizard.ps1')

# 服务运行状态常量
$script:McpServiceState = @{
    Stopped   = '未运行'
    Running   = '运行中'
    Zombie    = '僵尸PID（进程已消失，需清理）'
    PidReused = 'PID被复用（进程非本服务，需清理PID文件）'
    Unknown   = '未知'
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
# PID 与进程检测
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
    计算单个服务运行状态（含僵尸 PID 识别）。

.DESCRIPTION
    状态判定规则：
      - 无 PID 文件 → Stopped；
      - PID 文件存在但进程不存在 → Zombie（提示清理 PID 文件）；
      - 进程存在但命令行/路径不含服务目录 → PidReused（PID 被无关进程复用，提示清理 PID 文件，绝不误杀）；
      - 进程存在且属于本服务 → Running。
#>
function Get-McpServiceStatus {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    foreach ($svc in $services) {
        $ready = (Get-McpConfigReadiness -Code $svc.Code | Select-Object -First 1).Ready
        $svcPid = Get-McpServicePid -Service $svc
        $state = $script:McpServiceState.Stopped
        $proc = $null
        if ($svcPid) {
            $proc = Get-McpProcessById -ProcessId $svcPid
            if (-not $proc) {
                $state = $script:McpServiceState.Zombie
            }
            elseif (Test-McpProcessOwnership -Process $proc -Service $svc) {
                $state = $script:McpServiceState.Running
            }
            else {
                $state = $script:McpServiceState.PidReused
            }
        }
        [pscustomobject]@{
            Code        = $svc.Code
            Id          = $svc.Id
            DisplayName = $svc.DisplayName
            State       = $state
            Pid         = $svcPid
            Ready       = $ready
            LogFile     = $svc.LogFile
            LogExists   = (Test-Path -LiteralPath $svc.LogFileFull)
            PidFile     = $svc.PidFile
            Process     = $proc
        }
    }
}

<#
.SYNOPSIS
    清理僵尸 PID 文件（进程已消失或 PID 被复用时删除 PID 文件）。
#>
function Remove-McpStalePidFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Service)
    $st = Get-McpServiceStatus -Code $Service.Code | Select-Object -First 1
    if ($st.State -ne $script:McpServiceState.Running -and (Test-Path -LiteralPath $Service.PidFileFull)) {
        Remove-Item -LiteralPath $Service.PidFileFull -Force
        Write-Host ("已清理 PID 文件：{0}（{1}）" -f $Service.PidFile, $st.State)
        Write-McpOpsLog -Action '清理PID' -Service $Service.Id -Detail $st.State
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    启动单个服务（内部核心）。

.DESCRIPTION
    仅当服务“配置就绪”时启动；未就绪跳过并中文提示（列出缺失项）。
    StartCommand 为注册表占位（$null/空）时提示待 M5–M8 接入。
    启动后写入 PID 文件；stdout/stderr 重定向到服务日志。
    任何异常只影响本服务，不阻断批量流程（由 Start-McpServices 兜底）。
#>
function Invoke-McpServiceStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [switch]$Quiet
    )
    $head = if ($Quiet) { { param($m) } } else { { param($m) Write-Host $m } }
    $readyInfo = Get-McpConfigReadiness -Code $Service.Code | Select-Object -First 1

    if (-not $readyInfo.Ready) {
        & $head ("[跳过] {0}：未配置就绪（缺失：{1}）。请先运行配置向导。" -f $Service.DisplayName, ($readyInfo.Missing -join ', '))
        Write-McpOpsLog -Action '启动跳过' -Service $Service.Id -Detail '未配置就绪'
        return [pscustomobject]@{ Code = $Service.Code; Started = $false; Reason = 'not-ready' }
    }

    if (-not $Service.StartCommand) {
        & $head ("[跳过] {0}：启动命令尚未接入（M5–M8 回填注册表 StartCommand 后可用）。" -f $Service.DisplayName)
        Write-McpOpsLog -Action '启动跳过' -Service $Service.Id -Detail 'StartCommand占位'
        return [pscustomobject]@{ Code = $Service.Code; Started = $false; Reason = 'no-command' }
    }

    # 已在运行则不重复启动
    $st = Get-McpServiceStatus -Code $Service.Code | Select-Object -First 1
    if ($st.State -eq $script:McpServiceState.Running) {
        & $head ("[跳过] {0}：已在运行（PID {1}）。" -f $Service.DisplayName, $st.Pid)
        return [pscustomobject]@{ Code = $Service.Code; Started = $false; Reason = 'already-running' }
    }
    if ($st.State -ne $script:McpServiceState.Stopped) {
        Remove-McpStalePidFile -Service $Service | Out-Null
    }

    try {
        $dir = Split-Path -Parent $Service.PidFileFull
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $logDir = Split-Path -Parent $Service.LogFileFull
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

        $proc = Start-Process -FilePath "$($Service.StartCommand[0])" `
            -ArgumentList "$($Service.StartCommand[1..($Service.StartCommand.Count - 1)])" `
            -WorkingDirectory (Get-McpRepoRoot) `
            -RedirectStandardOutput $Service.LogFileFull `
            -RedirectStandardError ($Service.LogFileFull -replace '\.log$', '.err.log') `
            -WindowStyle Hidden -PassThru

        Set-Content -LiteralPath $Service.PidFileFull -Value $proc.Id -Encoding ASCII
        & $head ("[启动] {0}：PID {1}（日志 {2}）" -f $Service.DisplayName, $proc.Id, $Service.LogFile)
        Write-McpOpsLog -Action '启动' -Service $Service.Id -Detail ("PID={0}" -f $proc.Id)
        return [pscustomobject]@{ Code = $Service.Code; Started = $true; Pid = $proc.Id; Reason = 'ok' }
    }
    catch {
        & $head ("[失败] {0}：{1}" -f $Service.DisplayName, $_.Exception.Message)
        Write-McpOpsLog -Action '启动失败' -Service $Service.Id -Detail $_.Exception.Message
        return [pscustomobject]@{ Code = $Service.Code; Started = $false; Reason = 'error' }
    }
}

<#
.SYNOPSIS
    批量启动服务：只启动“已就绪”的服务；单个失败不阻断其余。

.PARAMETER Code
    指定服务代号（A/B/C/D）启动单个；省略则批量启动全部就绪服务。
#>
function Start-McpServices {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    $results = @()
    foreach ($svc in $services) {
        $results += Invoke-McpServiceStart -Service $svc
    }
    return $results
}

# ---------------------------------------------------------------------------
# 停止（通知 → 等待 → 二次确认 → 强制）
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    停止单个服务：通知退出 → 轮询等待全局超时 → 超时二次确认 → 强制结束。

.DESCRIPTION
    - “通知退出”先以 taskkill（不带 /F）尝试；无窗口进程通常无效，M5–M8 可按服务定制。
    - 等待时长取注册表全局参数 GracefulStopTimeoutSeconds，按 StopPollingIntervalSeconds 轮询。
    - 超时后询问是否强制结束（taskkill /F /T 连带子进程树）。
    - PID 被无关进程复用（PidReused）时只清理 PID 文件，绝不误杀他人进程。
    - 成功后清理 PID 文件。
#>
function Invoke-McpServiceStop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Service,
        [switch]$Quiet
    )
    $head = if ($Quiet) { { param($m) } } else { { param($m) Write-Host $m } }
    $global = Get-McpGlobalConfig
    $st = Get-McpServiceStatus -Code $Service.Code | Select-Object -First 1

    if ($st.State -eq $script:McpServiceState.Stopped) {
        & $head ("[停止] {0}：未在运行。" -f $Service.DisplayName)
        return [pscustomobject]@{ Code = $Service.Code; Stopped = $true; Reason = 'not-running' }
    }
    if ($st.State -eq $script:McpServiceState.Zombie -or $st.State -eq $script:McpServiceState.PidReused) {
        & $head ("[停止] {0}：{1}。" -f $Service.DisplayName, $st.State)
        Remove-McpStalePidFile -Service $Service | Out-Null
        return [pscustomobject]@{ Code = $Service.Code; Stopped = $true; Reason = 'stale-pid-cleaned' }
    }

    $svcPid = $st.Pid
    & $head ("[停止] {0}：通知进程 PID {1} 退出（优雅等待最长 {2} 秒）…" -f $Service.DisplayName, $svcPid, $global.GracefulStopTimeoutSeconds)
    Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $svcPid" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null

    $deadline = (Get-Date).AddSeconds($global.GracefulStopTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-McpProcessById -ProcessId $svcPid)) { break }
        Start-Sleep -Seconds $global.StopPollingIntervalSeconds
    }

    if (Get-McpProcessById -ProcessId $svcPid) {
        $ans = if ($Quiet) { $true } else { (Read-Host -Prompt ("优雅退出超时。是否强制结束 PID {0} 及其子进程？[y/N]" -f $svcPid)) -match '^(y|Y|是)$' }
        if ($ans) {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $svcPid /T /F" -WindowStyle Hidden | Out-Null
            Start-Sleep -Seconds $global.StopPollingIntervalSeconds
        }
        else {
            & $head ("[停止] {0}：已保留进程运行（PID {1}）。" -f $Service.DisplayName, $svcPid)
            Write-McpOpsLog -Action '停止放弃' -Service $Service.Id -Detail ("PID={0} 保留" -f $svcPid)
            return [pscustomobject]@{ Code = $Service.Code; Stopped = $false; Reason = 'kept-by-user' }
        }
    }

    if (Get-McpProcessById -ProcessId $svcPid) {
        & $head ("[失败] {0}：强制结束仍失败（PID {1}），请人工处理。" -f $Service.DisplayName, $svcPid)
        Write-McpOpsLog -Action '停止失败' -Service $Service.Id -Detail ("PID={0}" -f $svcPid)
        return [pscustomobject]@{ Code = $Service.Code; Stopped = $false; Reason = 'force-failed' }
    }

    if (Test-Path -LiteralPath $Service.PidFileFull) { Remove-Item -LiteralPath $Service.PidFileFull -Force }
    & $head ("[停止] {0}：已退出并清理 PID。" -f $Service.DisplayName)
    Write-McpOpsLog -Action '停止' -Service $Service.Id -Detail ("PID={0}" -f $svcPid)
    return [pscustomobject]@{ Code = $Service.Code; Stopped = $true; Reason = 'ok' }
}

<#
.SYNOPSIS
    批量停止服务（省略 Code 时停止全部运行中服务）。
#>
function Stop-McpServices {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    $services = Get-McpServices
    if ($Code) { $services = $services | Where-Object { $_.Code -eq $Code.ToUpperInvariant() } }
    $results = @()
    foreach ($svc in $services) {
        $results += Invoke-McpServiceStop -Service $svc
    }
    return $results
}

# ---------------------------------------------------------------------------
# 状态表格
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    以表格输出全部服务状态：服务名、状态、PID、是否就绪、日志位置。
#>
function Show-McpServiceStatus {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Code)
    Get-McpServiceStatus @PSBoundParameters | ForEach-Object {
        [pscustomobject]@{
            '代号'     = $_.Code
            '服务'     = $_.DisplayName
            '状态'     = $_.State
            'PID'      = $_.Pid
            '配置就绪' = if ($_.Ready) { '是' } else { '否' }
            '日志位置' = $_.LogFile
        }
    } | Format-Table -AutoSize | Out-Host
    Write-McpOpsLog -Action '查看状态' -Service '-' -Detail 'ALL'
}
