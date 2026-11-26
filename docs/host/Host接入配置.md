# Host 接入配置

| 文档编号 | DOC-HOST-001 |
|---|---|
| 文档名称 | Host 接入配置 |
| 版本 | v0.7.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-25 |
| 最后更新 | 2026-11-26 |
| 关联里程碑 | M3（导出能力）、M5–M8（回填真实命令）、M10、统一配置改造、Magpie 网关接入、环境变量与工作流 |
| 评审人 | 自审 |
| 存放路径 | `docs/host/Host接入配置.md` |

> 模型一（ADR-006）：四个服务在 Host 中分别注册为独立 MCP 条目，由 Host 按需 stdio 拉起；mcpctl 菜单 6「导出 Host 配置」可生成本机可用的配置片段（command / args / env 为本机绝对路径，不含明文凭证；统一配置中已禁用的服务不导出）。示例中的路径为示意结构，实际值以本机导出结果为准。配置读取约定见 ADR-007：启动器通过 `env.MCP_SUITE_CONFIG` 找到仓库根统一配置 `mcp.config.json`。

## 0. 路径解析优先级

mcpctl 与四个启动器按同一顺序定位仓库根与统一配置；环境变量缺失时零配置可用：

| 顺序 | 依据 | 结果 |
|---|---|---|
| 1 | 环境变量 `MCP_SUITE_CONFIG`（配置文件的绝对路径） | 直接读取该文件；设置后不再看 `MCP_SUITE_ROOT` |
| 2 | 环境变量 `MCP_SUITE_ROOT`（仓库根目录的绝对路径） | 读取 `<MCP_SUITE_ROOT>\mcp.config.json`；mcpctl 以该目录为仓库根 |
| 3 | 两者都未设置 | 由脚本自身位置推断：`scripts\` 的上一级目录，配置为 `<仓库根>\mcp.config.json` |

- `MCP_SUITE_ROOT` 的生效条件：必须是绝对路径，且目录下存在 `scripts/mcpctl.config.ps1`；任一条不满足即视为无效。
- **无效时不回退**：mcpctl（主菜单、Bootstrap、登录预检）与四个启动器用下面两句原文报错，并给出清除命令——
  - 不是绝对路径：`环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：<值>。请改为正确的仓库根目录，或清除该变量后重试：setx MCP_SUITE_ROOT ""`
  - 不是本仓库根：`环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：<值>。请改为正确的仓库根目录，或清除该变量后重试：setx MCP_SUITE_ROOT ""`
- 设置方法：`setx MCP_SUITE_ROOT "<仓库根目录>"`。`setx` 只对之后新开的窗口生效；当前窗口可先执行 `set MCP_SUITE_ROOT=<仓库根目录>`（cmd）或 `$env:MCP_SUITE_ROOT = '<仓库根目录>'`（PowerShell）。
- 生效确认：运行 `scripts/mcpctl.ps1`，横幅会打印一行 `[根路径] 来自环境变量 MCP_SUITE_ROOT` 或 `[根路径] 由脚本位置推断`；Bootstrap 输出同样带这一行；菜单 7 登录预检的「根路径」项写明来源，变量无效时单独报错并给出修复命令。
- 与 Host 直连的关系：Host 条目仍建议保留 `env.MCP_SUITE_CONFIG`（优先级最高，不依赖进程环境）；`MCP_SUITE_ROOT` 主要用于 mcpctl 自身与不想逐条带 env 的场景。
- CI 校验：报错文案在 mcpctl 与四个启动器之间保持一致（防手改漂移），并做「未设置 / 设为仓库根 / 设错」三态自检。

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

## 4. Magpie 网关模式（可选）

Magpie（本机 MCP 网关，Windows 原生托盘程序）可以作为四个服务的**可选中间层**：它以命令模式登记同一组启动命令，统一拉起进程，再把工具转给各 agent 或持密钥的客户端。默认接入方式仍是第 1～3 节的 Host 直连（ADR-006）；网关模式是 ADR-008 定义的例外，按需选用。

### 4.1 四条路由

仓库根的 `gateway.routes.sample.json` 是路由样例（`<仓库根>` 为占位符，不含凭证与本机信息）；四条 `command` / `args` 与 `scripts/mcpctl.config.ps1` 的 `StartCommand` 一致，由 CI 校验（启动命令变更时样例必须同步）。登记时把 `<仓库根>` 换成本机仓库绝对路径：

| 服务名（固定，不加前缀） | command | args | env |
|---|---|---|---|
| `Gerrit` | `<仓库根>\mcp-gerrit\venv\Scripts\python.exe` | `<仓库根>\mcp-gerrit\launcher.py` | `MCP_SUITE_CONFIG=<仓库根>\mcp.config.json` |
| `GitHub` | `node` | `<仓库根>\mcp-github\launcher.mjs` | 同上 |
| `Jenkins` | `node` | `<仓库根>\mcp-jenkins\launcher.mjs` | 同上 |
| `Atlassian` | `<仓库根>\mcp-atlassian\venv\Scripts\python.exe` | `<仓库根>\mcp-atlassian\launcher.py` | 同上 |

登记方式：在 Magpie 界面的 Library → MCP 中逐条录入，或用命令行等价登记（以 Gerrit 为例，其余三条同理）：

```
magpie library mcp add Gerrit <仓库根>\mcp-gerrit\venv\Scripts\python.exe <仓库根>\mcp-gerrit\launcher.py env=MCP_SUITE_CONFIG=<仓库根>\mcp.config.json --local
magpie library mcp agents Gerrit <agent1,agent2,…>
```

填写纪律：
- `args` 里不补 `stdio`（启动器已固定该子命令）；`node` 依赖 PATH。
- 路由里只放 `env.MCP_SUITE_CONFIG`，不得出现任何凭证类字样；凭证仍只在本机 `mcp.config.json`，由启动器在进程内读取。
- 条目含本机绝对路径，登记时标记为仅本机（`--local`），不随同步或备份外传；填好真实路径的版本如需保存，命名为 `gateway.routes.json`（已被 `.gitignore` 排除）。

实测结果（2026-11-26，Magpie 0.1.4572，Windows 原生，本机）：四条登记成功；`env` 透传到启动器（四个启动器均因拿到 `MCP_SUITE_CONFIG` 而正常启动）；工具数 Gerrit 20 / GitHub 46 / Jenkins 14 / Atlassian 98；四条只读调用（`Gerrit__query_changes`、`GitHub__get_me`、`Jenkins__getJobs`、`Atlassian__jira_get_all_projects`）各成功一次。

### 4.2 按需行为（与直连的差异）

- 直连：Host 在首次需要时拉起对应服务，Host 退出后服务退出。
- 网关：Magpie **按服务懒启动**。客户端接入网关、检索工具（`find_tools`）时不会启动任何服务进程；某个服务**第一次被调用**（`call_tool`）时才拉起该服务（实测：依次调用四个服务，服务进程数 0 → 5（Gerrit）→ 7（+GitHub）→ 8（+Jenkins）→ 10（+Atlassian））。会话结束后进程**不立即退出**，Magpie 复用它们供后续会话使用，**空闲约 10 分钟后回收**（实测：会话结束后空闲 568 秒时 10 个进程仍在，599 秒时全部退出）。这是 ADR-006「Host 直连、会话结束即退出」在回收时机上的例外（ADR-008），不是常驻。
- 首次使用（Magpie 尚未缓存工具目录）时，`find_tools` 需要真实发现工具，四个服务会在检索阶段被逐个启动；之后检索走缓存。
- 因此统一配置 `mcp.config.json` 修改后，需要让 Magpie 重新拉起服务（等空闲回收，或退出并重启 Magpie）才会生效。

### 4.3 客户端（网关密钥）分组授权

网关密钥用于给外部客户端发放受限访问，只在 Magpie 内创建与保管，不写入仓库。建议分组如下（**尚未创建**，待负责人按需执行；Atlassian 的范围收窄待确认）：

| 密钥给谁 | 允许的服务 | 工具规模 | 授权方式 |
|---|---|---|---|
| 开发客户端 | Gerrit + GitHub | 66 | 只放行两服务的只读工具 |
| 值班 / CI 机器人 | Jenkins | 14 | 只放行 `getJobs`、`getBuild`、`whoAmI` 等只读工具 |
| 项目文档场景 | Atlassian | 98 → 收窄后更少 | 只放行 `jira_search`、`confluence_search`、`confluence_get_page` 等只读工具；`projectScope` / `spaceScope` 是统一配置的单文件设置，对所有使用者生效，无法只对一把密钥收窄——需要独立范围时须另建使用独立配置的条目（待确认） |
| 手机临时查看 | GitHub + Jenkins | 60 | 只放行只读工具 |

规则：一律只读；写工具（`jira_create_issue`、`confluence_create_page`、`post_review_comment`、GitHub 写接口、`triggerBuild` 等）不给任何客户端。创建密钥时带 `--read-only`，并用 `magpie gateway-key mcp <密钥> <服务>/<工具>…` 逐工具放行。

### 4.4 工具命名

网关给每个工具加服务前缀：`<服务名>__<工具名>`（如 `Gerrit__query_changes`、`Jenkins__getJobs`）。agent 通过网关只看到两个元工具 `find_tools` 与 `call_tool`，按需检索与调用；四个服务共 178 个工具，加前缀后无同名项。

### 4.5 回退到直连

- 撤下网关里的条目：`magpie library mcp off <服务名>`（设置保留，`magpie library mcp on <服务名>` 可恢复）；只从部分 agent 撤下用 `magpie library mcp agents <服务名> <agent,…|none>`。
- 直连配置用 `scripts/mcpctl.ps1` 菜单 6 导出（第 2 节结构）。
- 同一个 agent 不要对同一服务同时启用网关与直连，否则会出现两套同类工具。

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v0.1.0 | 2026-11-25 | zeek.zhao | 建立 Host 接入配置骨架 | 项目初始化 |
| v0.2.0 | 2026-11-25 | zeek.zhao | 升级为模型一可用结构模板：Host 直接拉起、凭证注入规则、遗留进程验证项 | DEV-003/004，ADR-006，Issue #20 |
| v0.3.0 | 2026-11-25 | zeek.zhao | 四条目 command/args 按 StartCommand 回填后的最终形态更新（gerrit venv exe+--config+stdio、node+launcher、venv python+launcher.py） | P0-1/P0-3，DEV-008/009，Issue #39 |
| v0.4.0 | 2026-11-26 | zeek.zhao | 四条目改为启动器形态（gerrit 改为 venv python + launcher.py）并补充 env.MCP_SUITE_CONFIG；接入原则与注入规则改为统一配置口径；验证清单补充 MCP_SUITE_CONFIG 检查项 | 统一配置改造（ADR-007，T-DOC-01，Issue #57） |
| v0.5.0 | 2026-11-26 | zeek.zhao | 验证清单「Host 退出后无残留进程」的复核方法更正：总控的遗留进程检测基于 PID 文件，不覆盖 Host 拉起的进程，改为引用端到端验收清单的进程观察命令 | 与实现对齐（T-VER-03，Issue #71） |
| v0.6.0 | 2026-11-26 | zeek.zhao | 新增第 4 节「Magpie 网关模式（可选）」：四条路由与登记方式、按需行为实测（按服务懒启动、会话结束后空闲约 10 分钟回收）、客户端密钥分组授权建议（尚未创建）、工具命名与回退直连方法 | Magpie 网关接入（TASK-PROXY-01，ADR-008，Issue #85） |
| v0.7.0 | 2026-11-26 | zeek.zhao | 新增第 0 节「路径解析优先级」：`MCP_SUITE_CONFIG` > `MCP_SUITE_ROOT` > 脚本位置推断；`MCP_SUITE_ROOT` 无效时不回退、两句报错原文与清除命令；设置方法、生效确认与 CI 校验说明 | 环境变量与工作流（T-ENV-01，Issue #89） |
