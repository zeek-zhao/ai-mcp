# Host 接入配置

| 文档编号 | DOC-HOST-001 |
|---|---|
| 文档名称 | Host 接入配置 |
| 版本 | v0.2.0 |
| 状态 | 草稿（D） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-25 |
| 最后更新 | 2026-11-25 |
| 关联里程碑 | M3（导出能力）、M5–M8（回填真实命令）、M10 |
| 评审人 | 自审 |
| 存放路径 | `docs/host/Host接入配置.md` |

> 模型一（ADR-006）：四个服务在 Host 中分别注册为独立 MCP 条目，由 Host 按需 stdio 拉起；mcpctl 菜单“导出 Host 配置”可生成本文件所示结构的片段（不含明文凭证）。示例中的解释器/入口路径为示意结构，真实值在对应接入里程碑（M5–M8）回填。

## 1. 接入原则

- Host 分别为 `mcp-gerrit`、`mcp-github`、`mcp-jenkins`、`mcp-atlassian` 注册独立条目。
- 启动命令由 Host 直接拉起服务进程：command 指向解释器/可执行文件（优先仓库内 venv 或仓库内依赖目录），args 指向服务入口与本地配置文件路径；**不经过总控脚本托管**。
- 凭证通过本地配置文件注入，不在 Host 配置中明文填写 Token。

## 2. 配置示例（结构模板；真实 command/args 在 M5–M8 回填）

> 路径示意（绝对路径由各机器本地决定，务必使用本机实际路径；`<...>` 为接入里程碑回填位）：

### 2.1 Cursor / 兼容 MCP 的客户端
```json
{
  "mcpServers": {
    "gerrit": {
      "command": "<M5 回填：mcp-gerrit 仓库内 venv 的 python.exe 路径>",
      "args": ["<M5 回填：gerrit-mcp-server 入口参数>", "mcp-gerrit/gerrit_config.json"],
      "env": {}
    },
    "github": {
      "command": "<node.exe 路径>",
      "args": ["<仓库路径>/mcp-github/launcher.mjs"],
      "env": {}
    },
    "jenkins": {
      "command": "<M7 回填：node.exe 路径>",
      "args": ["<仓库路径>/mcp-jenkins/launcher.mjs"],
      "env": {}
    },
    "atlassian": {
      "command": "<本地路径>\\ai-mcp\\mcp-atlassian\\venv\\Scripts\\python.exe（先运行 scripts/bootstrap.ps1 初始化）",
      "args": ["<本地路径>\\ai-mcp\\mcp-atlassian\\launcher.py"],
      "env": {}
    }
  }
}
```

**注入规则（重要）**
- `env` 与 `args` 中一律**不得出现明文 Token/密码**；凭证只存在于本地被 gitignore 的配置文件（`*_config.json`、`.env`），由服务实现启动时读取，或在 Host 配置中引用变量注入方式（M5–M8 按各实现确定）。
- 可用 `scripts/mcpctl.ps1` 菜单 6「导出 Host 配置」生成本结构片段（不含凭证），再手工补齐 command/args。
- 修改 Host 配置后重启 Host 使其重新按需拉起服务。

### 2.2 Claude Desktop
- 配置文件 `claude_desktop_config.json`，条目结构与 2.1 相同（`mcpServers` 键）；真实示例在 M10 按官方当前文档核对回填。

## 3. 接入验证清单

- [ ] 四个服务条目均被 Host 识别。
- [ ] 每个服务可完成一次只读探活调用。
- [ ] Host 配置中不含明文凭证。
- [ ] Host 退出后服务进程随之退出，无遗留进程（可用总控「遗留进程检测」复核）。

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v0.1.0 | 2026-11-25 | zeek.zhao | 建立 Host 接入配置骨架 | 项目初始化 |
| v0.2.0 | 2026-11-25 | zeek.zhao | 升级为模型一可用结构模板：Host 直接拉起、凭证注入规则、遗留进程验证项 | DEV-003/004，ADR-006，Issue #20 |
