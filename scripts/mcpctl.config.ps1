#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 总控配置：服务注册表与全局参数（M1；T-CFG-02 起接入统一配置）。

.DESCRIPTION
    本文件是 mcpctl 全家桶的【唯一数据源】，仅包含数据定义，不含任何执行逻辑。
    由 scripts/lib/registry.ps1 及后续 mcpctl 脚本 dot-source 加载。

    新增服务规范：只需在下方 $script:McpServices 数组【追加一条】，
    字段齐全即可被所有 mcpctl 脚本识别，无需修改其他逻辑代码。
    新增服务时须同时在 mcp.config.sample.json 的 services 中增加同名配置段
    （Test-McpRegistry 会校验两者一致）。

    统一配置：四个服务的连接信息与凭证集中在仓库根 mcp.config.json（真实文件已被
    .gitignore 排除，仓库只分发模板 mcp.config.sample.json）。字段含义见
    docs/services/配置字段说明.md；读写入口统一在 scripts/lib/suite-config.ps1。

.NOTES
    字段说明（服务条目，8 项必填，另 1 项可选）：
      Code           服务代号（受控服务清单中的 A/B/C/D，唯一）
      Id             子目录名（唯一，与仓库目录一致）
      DisplayName    显示名（全中文菜单展示）
      StartCommand   实际拉起命令（数组；以仓库相对路径书写，运行时由 registry.ps1 的
                     Resolve-McpStartCommand 归一化为绝对路径后使用）
      ConfigKey      统一配置 mcp.config.json 中 services 下的段名（唯一，须与
                     mcp.config.sample.json 的 services 键一致）
      PidFile        PID 文件路径（仓库相对路径，运行时生成）
      LogFile        日志文件路径（仓库相对路径，运行时生成）
      Stack          技术栈标识（python / node / binary，供 Bootstrap 与环境预检使用）
      BinaryPath     可选：binary 技术栈的可执行文件路径（仓库相对路径）；缺省时按 <服务Id>.exe 探测
      语义说明：Stack 表示【依赖获取方式】（Bootstrap 依据，如 mcp-github 的 binary 表示二进制由
      setup-github-mcp.ps1 下载落位）；StartCommand 表示【实际拉起方式】（Host / 探活使用，如
      mcp-github 实际由 node 启动 launcher.mjs）。二者允许不同。
#>

# ---------------------------------------------------------------------------
# 全局参数
# ---------------------------------------------------------------------------

# 仓库根目录定位方式：本文件位于 <仓库根>/scripts/ 下，$PSScriptRoot 即 scripts 目录，
# 取其上一级即为仓库根。不依赖当前工作目录，任何位置调用均以本文件自身位置反推仓库根。
# 环境变量 MCP_SUITE_ROOT 可覆盖上述结果（已设置但无效时不回退，见 lib/registry.ps1，T-ENV-01）。
$script:McpRepoRoot = (Split-Path -Parent $PSScriptRoot)

$script:McpCtlGlobal = @{
    # 仓库根目录（绝对路径，运行时计算）
    RepoRoot = $script:McpRepoRoot

    # 运行日志根目录（仓库相对；.gitignore 已排除 logs/）
    LogRoot = 'logs'

    # 统一配置文件（仓库相对路径）：四个服务的连接信息与凭证全部集中在这一份文件中。
    # 真实文件含凭证，已被 .gitignore 排除；读写入口见 scripts/lib/suite-config.ps1。
    SuiteConfigPath = 'mcp.config.json'

    # 进程退出等待超时（秒）：遗留进程清理（taskkill /F /T 强杀进程树）后等待进程消失的最长时间，
    # 超时提示人工处理（模型一：mcpctl 不启动/停止服务，见 ADR-006）
    GracefulStopTimeoutSeconds = 15

    # 强制结束前等待进程退出的轮询间隔（秒）
    StopPollingIntervalSeconds = 1

    # ---- 登录预检与环境自愈（M9，入口：菜单 7 / scripts\autostart.ps1）----
    # 环境自愈开关：$true 表示预检发现依赖环境缺失时直接调用 Bootstrap（初始化缺失环境）；
    # $false（默认）只给出修复命令，交互式菜单下会逐次询问确认。
    PreflightAutoBootstrap = $false

    # 登录触发：默认关闭。本工具不创建计划任务；如需登录时自动预检，由用户自行创建仅做预检的任务
    # （命令见 scripts\autostart.ps1 头部说明）。开启后也只做预检，不做常驻（ADR-006）。
    PreflightLoginTrigger = $false

    # 菜单与交互语言（本项目固定全中文）
    MenuLanguage = 'zh-CN'
}

# ---------------------------------------------------------------------------
# 服务注册表
# 说明：StartCommand 为仓库相对路径，运行时归一化为绝对路径（见 scripts/lib/registry.ps1）。
#       ConfigKey 对应统一配置 mcp.config.json 的 services.<ConfigKey> 配置段。
# ---------------------------------------------------------------------------

$script:McpServices = @(
    @{
        Code           = 'A'
        Id             = 'mcp-gerrit'
        DisplayName    = 'Gerrit 代码评审'
        StartCommand   = @('mcp-gerrit/venv/Scripts/python.exe', 'mcp-gerrit/launcher.py')
        ConfigKey      = 'gerrit'
        PidFile        = 'mcp-gerrit/run.pid'
        LogFile        = 'mcp-gerrit/logs/service.log'
        Stack          = 'python'
    },
    @{
        Code           = 'B'
        Id             = 'mcp-github'
        DisplayName    = 'GitHub / GitHub Enterprise'
        StartCommand   = @('node', 'mcp-github/launcher.mjs')
        ConfigKey      = 'github'
        PidFile        = 'mcp-github/run.pid'
        LogFile        = 'mcp-github/logs/service.log'
        Stack          = 'binary'
        BinaryPath     = 'mcp-github/bin/github-mcp-server.exe'   # setup-github-mcp.ps1 下载后落位（bin/ 已 gitignore）
    },
    @{
        Code           = 'C'
        Id             = 'mcp-jenkins'
        DisplayName    = 'Jenkins CI（零插件）'
        StartCommand   = @('node', 'mcp-jenkins/launcher.mjs')
        ConfigKey      = 'jenkins'
        PidFile        = 'mcp-jenkins/run.pid'
        LogFile        = 'mcp-jenkins/logs/service.log'
        Stack          = 'node'
    },
    @{
        Code           = 'D'
        Id             = 'mcp-atlassian'
        DisplayName    = 'Atlassian Jira + Confluence'
        StartCommand   = @('mcp-atlassian/venv/Scripts/python.exe', 'mcp-atlassian/launcher.py')
        ConfigKey      = 'atlassian'
        PidFile        = 'mcp-atlassian/run.pid'
        LogFile        = 'mcp-atlassian/logs/service.log'
        Stack          = 'python'
    }
)
