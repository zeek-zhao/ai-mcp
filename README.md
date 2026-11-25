# ai-mcp · 本地 MCP 套件

> 在 Windows 本地运行的一组独立 MCP Server，统一对接 Gerrit、GitHub、Jenkins、Atlassian（Jira + Confluence），由全中文总控脚本按需启停。

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
| 服务接入说明 | `docs/services/服务接入说明.md` | 四个服务的选型、配置项、能力与已知限制 |
| 安全与凭证管理 | `docs/security/安全与凭证管理.md` | 凭证、权限、密钥扫描与审计要求 |
| Host 接入配置 | `docs/host/Host接入配置.md` | Cursor / Claude Desktop 等 Host 的接入示例 |
| 任务清单 | `docs/operations/任务清单.md` | 可执行任务条目、状态、依赖、验收标准 |
| 问题记录 | `docs/operations/问题记录.md` | 开发过程中遇到的问题、原因、措施与状态 |
| 更新记录 | `docs/operations/更新记录.md` | 每次版本/提交做了什么的变更日志 |

### 给 AI 读的文档（`ai/`）
> AI 进入仓库后，**先读 `ai/README.md`**，按其中的阅读顺序与约束执行。

| 文档 | 路径 | 说明 |
|---|---|---|
| AI 入口说明 | `ai/README.md` | 阅读顺序、工作边界、交付要求 |
| 全局上下文 | `ai/全局上下文.md` | 项目背景、不可更改的架构决策、硬性约束 |
| 实现提示词 | `ai/实现提示词.md` | 按里程碑拆分的可执行提示词 |
| 交付与 PR 规范 | `ai/交付与PR规范.md` | 分支、提交、PR、自检与回执模板 |

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
├─ .github/                 # Issue/PR 模板、CI、CODEOWNERS
├─ docs/                    # 工程文档（人读）
├─ ai/                      # AI 指令文档（AI 读）
├─ scripts/                 # 总控脚本（PowerShell）
│  └─ lib/
├─ mcp-gerrit/
├─ mcp-github/
├─ mcp-jenkins/
└─ mcp-atlassian/
```

## 四、当前阶段

- 阶段：**M0–M4 完成；M5–M8 实现与依赖接入完成，验收待执行**（需配置真实凭证后执行四服务的 Host 握手验收与连通测试；Gerrit 已在真实环境实测连通）。
- 下一阶段：M5–M8 验收（TASK-M5-02 ~ TASK-M8-02），随后 M9（登录预检与环境自愈）。按 `docs/operations/任务清单.md` 与 `ai/实现提示词.md` 逐里程碑推进。

## 五、安全提示

- 真实 Token、密码、私钥、内部地址**一律不入库**；仓库只保留 `*.sample` / `*.template` 模板。
- 任何凭证只写入本地被 `.gitignore` 排除的配置文件。
- 若凭证曾在聊天、截图、提交记录中暴露，应立即在对应系统重置，并登记到 `docs/operations/问题记录.md`。
