# ai-mcp · 本地 MCP 套件

> 在 Windows 本地运行的一组独立 MCP Server，统一对接 Gerrit、GitHub、Jenkins、Atlassian（Jira + Confluence），由全中文总控脚本统一配置与诊断，服务由 Host 按需以 stdio 拉起。

| 项目 | 内容 |
|---|---|
| 仓库 | zeek-zhao/ai-mcp |
| 目标平台 | Windows（本地运行，优先 stdio 按需拉起） |
| 架构 | 多独立 MCP Server（一服务一进程，禁止单聚合大单体） |
| 协作方式 | GitHub 仓库 + Issue / PR / Milestone 流程 |
| 文档模式 | ISO 风格文档控制（编号、版本、变更记录、台账留痕） |

## 一、快速导航

### 给人看的工程文档（`docs/`）
| 文档 | 路径 | 说明 |
|---|---|---|
| 文档管理规范 | `docs/00-文档管理规范.md` | 编号、版本、状态、目录与变更记录规则，新增文档前必读 |
| 文档台账 | `docs/01-文档台账.md` | 全部文档的登记清单（编号、版本、状态、路径、负责人） |
| 项目计划书 | `docs/planning/项目计划书.md` | 背景、目标、约束、选型、范围 |
| 里程碑规划 | `docs/planning/里程碑规划.md` | M0–M10 里程碑划分与依赖关系 |
| 架构与决策记录 | `docs/architecture/架构与决策记录.md` | 架构决策（ADR）与取舍理由 |
| 服务接入说明 | `docs/services/服务接入说明.md` | 四个服务的选型、配置段、能力与已知限制 |
| 配置字段说明 | `docs/services/配置字段说明.md` | 统一配置 `mcp.config.json` 的字段表、参考值与填写规则 |
| 安全与凭证管理 | `docs/security/安全与凭证管理.md` | 凭证、权限、密钥扫描与审计要求 |
| Host 接入配置 | `docs/host/Host接入配置.md` | Cursor / Claude Desktop 等 Host 的接入示例 |
| 任务清单 | `docs/operations/任务清单.md` | 可执行任务条目、状态、依赖、验收标准 |
| 问题记录 | `docs/operations/问题记录.md` | 开发过程中遇到的问题、原因、措施与状态 |
| 更新记录 | `docs/operations/更新记录.md` | 每次版本/提交做了什么的变更日志 |
| 验收记录-M5至M8 | `docs/operations/验收记录-M5至M8.md` | 四服务 Host 握手与连通验收步骤（结论由负责人人工执行后回填） |
| 验收记录-M10 | `docs/operations/验收记录-M10.md` | Host 端到端验收清单：可见 4 个服务、按需拉起、退出无残留、日志无凭证、配置生效时机（结论由负责人人工执行后回填） |

### 给 AI 读的文档（`ai/`）
> AI 进入仓库后，**先读 `ai/README.md`**，按其中的阅读顺序与约束执行。

| 文档 | 路径 | 说明 |
|---|---|---|
| AI 入口说明 | `ai/README.md` | 阅读顺序、工作边界、交付要求 |
| 全局上下文 | `ai/全局上下文.md` | 项目背景、不可更改的架构决策、硬性约束 |
| 实现提示词 | `ai/实现提示词.md` | 按里程碑拆分的可执行提示词 |
| 交付与 PR 规范 | `ai/交付与PR规范.md` | 分支、提交、PR、自检与回执模板 |
| 仓库开发技能 | `skills/ai-mcp-dev/SKILL.md` | 定义性开发技能：架构约束、里程碑流程、交付规范、文档管控与安全红线 |

## 二、受控服务清单

| 代号 | 目录 | 对接系统 | 备注 |
|---|---|---|---|
| A | `mcp-gerrit/` | Gerrit 代码评审 | 评审模型独立，单独封装 |
| B | `mcp-github/` | GitHub / GitHub Enterprise | 本地部署模式，不使用远程托管端点 |
| C | `mcp-jenkins/` | Jenkins CI | **零插件、零实例改造**，仅 REST API 调用 |
| D | `mcp-atlassian/` | Atlassian Jira + Confluence | 一体化本地服务，内网 DC/Server |

## 三、目录结构（目标态）

```
ai-mcp/
├─ README.md
├─ .gitignore
├─ mcp.config.sample.json    # 统一配置模板（四服务共用；字段说明见 docs/services/配置字段说明.md）
├─ mcp.config.schema.json    # 统一配置结构契约（CI 据此校验模板）
├─ mcp.config.json           # 本地真实配置（含凭证，不入库；由配置向导生成）
├─ .github/                 # Issue/PR 模板、CI、CODEOWNERS
├─ docs/                    # 工程文档（人读）
├─ ai/                      # AI 指令文档（AI 读）
├─ scripts/                 # 总控脚本（PowerShell）
│  └─ lib/
├─ mcp-gerrit/              # 服务目录：启动器（读取统一配置）+ 依赖清单与锁定文件
├─ mcp-github/
├─ mcp-jenkins/
└─ mcp-atlassian/
```

## 四、当前阶段

- 阶段：**M0–M9 完成；统一配置改造（ADR-007）完成；M10 验收清单已就绪，待负责人执行**。四个服务与总控共用仓库根的 `mcp.config.json`：配置向导逐字段录入，启动器经 `MCP_SUITE_CONFIG` 读取，Host 配置导出自带 env；分服务配置模板已下线。登录预检与环境自愈见菜单 7。真实只读连通验证：Gerrit、GitHub、Jenkins、Jira、Confluence 均已由 AI 用负责人提供的凭证验证成功（待负责人签字确认，记录见验收记录各服务的「执行记录」）；Jira 与 Confluence 令牌不同时，在统一配置填写可选字段 `confluencePersonalAccessToken`。
- 下一阶段：人工验收与回填——先按 `docs/operations/验收记录-M5至M8.md` 完成四服务 Host 握手与连通验收（TASK-M5-02 ~ TASK-M8-02），再按 `docs/operations/验收记录-M10.md` 完成 Host 端到端验收（TASK-M10-01）并回填结论。DEV-001 的处置决定已留痕（暂缓重置，状态保持开放）。
- 快速上手：复制 `mcp.config.sample.json` 为 `mcp.config.json` 后运行 `scripts/mcpctl.ps1`（菜单 4 配置向导逐字段录入 → 菜单 5 Bootstrap 初始化依赖 → 菜单 7 登录预检确认无未通过项 → 菜单 6 导出 Host 配置）；字段含义见 `docs/services/配置字段说明.md`。复制后必须替换全部 example / zhangsan 类参考值（或直接用菜单 4 配置向导逐字段录入），否则服务不会被判定就绪。仓库不在固定位置时，设置环境变量 `MCP_SUITE_ROOT`（仓库根目录的绝对路径）即可，规则见 `docs/host/Host接入配置.md` 第 0 节。

## 五、安全提示

- 真实 Token、密码、私钥、内部地址**一律不入库**；仓库只保留统一配置模板 `mcp.config.sample.json` 与结构契约 `mcp.config.schema.json`。
- 凭证只写入本地的统一配置 `mcp.config.json`（已被 `.gitignore` 排除），不写入服务目录、日志或 Host 配置文件。
- 若凭证曾在聊天、截图、提交记录中暴露，应立即在对应系统重置，并登记到 `docs/operations/问题记录.md`。
