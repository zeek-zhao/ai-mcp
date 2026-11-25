#Requires -Version 5.1
<#
.SYNOPSIS
    mcpctl 总控配置：服务注册表与全局参数（M1）。

.DESCRIPTION
    本文件是 mcpctl 全家桶的【唯一数据源】，仅包含数据定义，不含任何执行逻辑。
    由 scripts/lib/registry.ps1 及后续 mcpctl 脚本 dot-source 加载。

    新增服务规范：只需在下方 $script:McpServices 数组【追加一条】，
    字段齐全即可被所有 mcpctl 脚本识别，无需修改其他逻辑代码。

.NOTES
    字段说明（服务条目，共 9 项）：
      Code           服务代号（受控服务清单中的 A/B/C/D，唯一）
      Id             子目录名（唯一，与仓库目录一致）
      DisplayName    显示名（全中文菜单展示）
      StartCommand   启动命令（占位，待 M5–M8 按各服务实现回填；$null = 未接入）
      ConfigTemplate 配置模板路径（仓库相对路径，随仓库分发）
      LocalConfig    本地配置路径（仓库相对路径；真实凭证所在，已被 .gitignore 排除）
      PidFile        PID 文件路径（仓库相对路径，运行时生成）
      LogFile        日志文件路径（仓库相对路径，运行时生成）
      Stack          技术栈标识（python / node / binary，供 Bootstrap M4 与向导使用）
#>

# ---------------------------------------------------------------------------
# 全局参数
# ---------------------------------------------------------------------------

# 仓库根目录定位方式：本文件位于 <仓库根>/scripts/ 下，$PSScriptRoot 即 scripts 目录，
# 取其上一级即为仓库根。不依赖当前工作目录，任何位置调用均以本文件自身位置反推仓库根。
$script:McpRepoRoot = (Split-Path -Parent $PSScriptRoot)

$script:McpCtlGlobal = @{
    # 仓库根目录（绝对路径，运行时计算）
    RepoRoot = $script:McpRepoRoot

    # 运行日志根目录（仓库相对；.gitignore 已排除 logs/）
    LogRoot = 'logs'

    # 进程退出等待超时（秒）：遗留进程清理（taskkill /F /T 强杀进程树）后等待进程消失的最长时间，
    # 超时提示人工处理（模型一下 mcpctl 不启动/停止服务，见 ADR-006）
    GracefulStopTimeoutSeconds = 15

    # 强制结束前等待进程退出的轮询间隔（秒）
    StopPollingIntervalSeconds = 1

    # 菜单与交互语言（本项目固定全中文）
    MenuLanguage = 'zh-CN'
}

# ---------------------------------------------------------------------------
# 服务注册表
# 说明：启动命令当前为占位（$null），M5–M8 各服务接入时回填真实命令。
# ---------------------------------------------------------------------------

$script:McpServices = @(
    @{
        Code           = 'A'
        Id             = 'mcp-gerrit'
        DisplayName    = 'Gerrit 代码评审'
        StartCommand   = $null   # 占位：待 M5 回填（gerrit-mcp-server，Python stdio）
        ConfigTemplate = 'mcp-gerrit/gerrit_config.sample.json'
        LocalConfig    = 'mcp-gerrit/gerrit_config.json'
        PidFile        = 'mcp-gerrit/run.pid'
        LogFile        = 'mcp-gerrit/logs/service.log'
        Stack          = 'python'
    },
    @{
        Code           = 'B'
        Id             = 'mcp-github'
        DisplayName    = 'GitHub / GitHub Enterprise'
        StartCommand   = $null   # 占位：待 M6 回填（官方 github-mcp-server 本地部署，stdio）
        ConfigTemplate = 'mcp-github/.env.template'
        LocalConfig    = 'mcp-github/.env'
        PidFile        = 'mcp-github/run.pid'
        LogFile        = 'mcp-github/logs/service.log'
        Stack          = 'binary'
    },
    @{
        Code           = 'C'
        Id             = 'mcp-jenkins'
        DisplayName    = 'Jenkins CI（零插件）'
        StartCommand   = $null   # 占位：待 M7 回填（社区 jenkins-mcp，Node stdio，仅 REST API）
        ConfigTemplate = 'mcp-jenkins/jenkins_config.sample.json'
        LocalConfig    = 'mcp-jenkins/jenkins_config.json'
        PidFile        = 'mcp-jenkins/run.pid'
        LogFile        = 'mcp-jenkins/logs/service.log'
        Stack          = 'node'
    },
    @{
        Code           = 'D'
        Id             = 'mcp-atlassian'
        DisplayName    = 'Atlassian Jira + Confluence'
        StartCommand   = $null   # 占位：待 M8 回填（社区一体化 mcp-atlassian，Python）
        ConfigTemplate = 'mcp-atlassian/atlassian_config.sample.json'
        LocalConfig    = 'mcp-atlassian/atlassian_config.json'
        PidFile        = 'mcp-atlassian/run.pid'
        LogFile        = 'mcp-atlassian/logs/service.log'
        Stack          = 'python'
    }
)
