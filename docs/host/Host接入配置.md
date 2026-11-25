# Host 接入配置

| 文档编号 | DOC-HOST-001 |
|---|---|
| 文档名称 | Host 接入配置 |
| 版本 | v0.5.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-25 |
| 最后更新 | 2026-11-26 |
| 关联里程碑 | M3（导出能力）、M5–M8（回填真实命令）、M10、统一配置改造 |
| 评审人 | 自审 |
| 存放路径 | `docs/host/Host接入配置.md` |

> 模型一（ADR-006）：四个服务在 Host 中分别注册为独立 MCP 条目，由 Host 按需 stdio 拉起；mcpctl 菜单 6「导出 Host 配置」可生成本机可用的配置片段（command / args / env 为本机绝对路径，不含明文凭证；统一配置中已禁用的服务不导出）。示例中的路径为示意结构，实际值以本机导出结果为准。配置读取约定见 ADR-007：启动器通过 `env.MCP_SUITE_CONFIG` 找到仓库根统一配置 `mcp.config.json`。

## 1. 接入原则

- Host 分别为 `mcp-gerrit`、`mcp-github`、`mcp-jenkins`、`mcp-atlassian` 注册独立条目。
- 启动命令由 Host 直接拉起服务进程：command 指向解释器（仓库内 venv 的 `python.exe`，或 PATH 中的 `node`），args 指向各服务的启动器（`mcp-gerrit/launcher.py`、`mcp-github/launcher.mjs`、`mcp-jenkins/launcher.mjs`、`mcp-atlassian/launcher.py`）；**不经过总控脚本托管**。
- 每个条目带 `env.MCP_SUITE_CONFIG`，值为仓库根统一配置文件 `mcp.config.json` 的本机绝对路径；启动器据此读取本服务的配置段（`services.<key>`）。Host 配置中不出现明文 Token。

## 2. 配置示例（结构模板；实际路径以本机导出结果为准）

> 路径示意（`<仓库路径>` 为本机仓库绝对路径；实际值以 `scripts/mcpctl.ps1` 菜单 6 导出结果为准）：

### 2.1 Cursor / 兼容 MCP 的客户端
```json
{
  "mcpServers": {
    "gerrit": {
      "command": "<仓库路径>/mcp-gerrit/venv/Scripts/python.exe（先运行 scripts/bootstrap.ps1 初始化 venv）",
      "args": ["<仓库路径>/mcp-gerrit/launcher.py"],
      "env": { "MCP_SUITE_CONFIG": "<仓库路径>/mcp.config.json" }
    },
    "github": {
      "command": "node（或 node.exe 绝对路径；首次先联网运行 mcp-github/setup-github-mcp.ps1 获取 v2.1.0 二进制）",
      "args": ["<仓库路径>/mcp-github/launcher.mjs"],
      "env": { "MCP_SUITE_CONFIG": "<仓库路径>/mcp.config.json" }
    },
    "jenkins": {
      "command": "node（或 node.exe 绝对路径）",
      "args": ["<仓库路径>/mcp-jenkins/launcher.mjs（先运行 scripts/bootstrap.ps1 安装依赖）"],
      "env": { "MCP_SUITE_CONFIG": "<仓库路径>/mcp.config.json" }
    },
    "atlassian": {
      "command": "<仓库路径>/mcp-atlassian/venv/Scripts/python.exe（先运行 scripts/bootstrap.ps1 初始化）",
      "args": ["<仓库路径>/mcp-atlassian/launcher.py"],
      "env": { "MCP_SUITE_CONFIG": "<仓库路径>/mcp.config.json" }
    }
  }
}
```

> 条目名称可按习惯调整；mcpctl 导出结果使用服务目录名（`mcp-gerrit` 等），并额外附带 `note` 说明字段，Host 一般忽略该字段。

**注入规则（重要）**
- `env` 与 `args` 中一律**不得出现明文 Token/密码**；`env` 只放 `MCP_SUITE_CONFIG`（统一配置文件的本机绝对路径）。凭证只存在于本地被 gitignore 的 `mcp.config.json`，由启动器在进程内读取。
- 推荐用 `scripts/mcpctl.ps1` 菜单 6「导出 Host 配置」生成本机可用的完整片段（含 command / args / env），把其中 `mcpServers` 的内容粘贴到 Host 配置；统一配置中 `enabled=false` 的服务不会导出。
- 修改统一配置 `mcp.config.json` 后无需改 Host 配置：服务下次被 Host 拉起时读取新值（已运行的服务需重启 Host 或重新拉起后才生效）。
- 修改 Host 配置后重启 Host 使其重新按需拉起服务。

### 2.2 Claude Desktop
- 配置文件 `claude_desktop_config.json`，条目结构与 2.1 相同（`mcpServers` 键）；真实示例在 M10 按官方当前文档核对回填。

## 3. 接入验证清单

- [ ] 四个服务条目均被 Host 识别。
- [ ] 每个条目的 `env.MCP_SUITE_CONFIG` 指向本机存在的 `mcp.config.json`。
- [ ] 每个服务可完成一次只读探活调用。
- [ ] Host 配置中不含明文凭证。
- [ ] Host 退出后服务进程随之退出，无残留进程（按 `docs/operations/验收记录-M10.md` 步骤 C 的进程观察命令复核；总控的「遗留进程」检测基于 PID 文件，不覆盖 Host 拉起的进程）。

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v0.1.0 | 2026-11-25 | zeek.zhao | 建立 Host 接入配置骨架 | 项目初始化 |
| v0.2.0 | 2026-11-25 | zeek.zhao | 升级为模型一可用结构模板：Host 直接拉起、凭证注入规则、遗留进程验证项 | DEV-003/004，ADR-006，Issue #20 |
| v0.3.0 | 2026-11-25 | zeek.zhao | 四条目 command/args 按 StartCommand 回填后的最终形态更新（gerrit venv exe+--config+stdio、node+launcher、venv python+launcher.py） | P0-1/P0-3，DEV-008/009，Issue #39 |
| v0.4.0 | 2026-11-26 | zeek.zhao | 四条目改为启动器形态（gerrit 改为 venv python + launcher.py）并补充 env.MCP_SUITE_CONFIG；接入原则与注入规则改为统一配置口径；验证清单补充 MCP_SUITE_CONFIG 检查项 | 统一配置改造（ADR-007，T-DOC-01，Issue #57） |
| v0.5.0 | 2026-11-26 | zeek.zhao | 验证清单「Host 退出后无残留进程」的复核方法更正：总控的遗留进程检测基于 PID 文件，不覆盖 Host 拉起的进程，改为引用端到端验收清单的进程观察命令 | 与实现对齐（T-VER-03，Issue #71） |
