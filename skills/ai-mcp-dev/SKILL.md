---
name: ai-mcp-dev
description: zeek-zhao/ai-mcp 仓库的唯一定义性开发技能。凡在本仓库承接任何开发、修复、文档、CI 或发布任务时必须先加载本技能：它固化了不可更改的架构约束、里程碑流程与依赖链、GitHub Flow 交付规范、ISO 文档管控规则、安全红线，以及本地参考实现与已知坑。与本仓库 ai/ 文档冲突时以 ai/ 为准并向仓库维护人确认。
---

# ai-mcp 仓库开发技能（AI-SKILL-001）

| 属性 | 值 |
|---|---|
| 文档编号 | AI-SKILL-001 |
| 文档名称 | AI 开发技能文件 |
| 版本 | v1.3.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-25 |
| 最后更新 | 2026-11-26 |
| 关联里程碑 | M0–M10 |
| 评审人 | 自审 |
| 存放路径 | `skills/ai-mcp-dev/SKILL.md` |

> 本文件是仓库开发的**单一定义来源**：AI 承接任务时加载本技能即可获得全部开发规则；细节以 `ai/` 与 `docs/` 原文为准。

## 1. 仓库定位

Windows 本地多独立 MCP Server 套件：Gerrit / GitHub / Jenkins / Atlassian（Jira + Confluence）**一服务一独立进程**，由 **PowerShell 全中文菜单总控**（`scripts/mcpctl.ps1`）统一配置、启停、状态管理；Host 通过 stdio 按需拉起。

## 2. 动手前必读（固定顺序）

0. 本技能文件（已加载即视为已读）。
1. `ai/全局上下文.md` —— 背景与不可更改决策。
2. `ai/交付与PR规范.md` —— 分支/提交/PR/回执模板。
3. `docs/00-文档管理规范.md` —— 文档编号、版本、目录、变更记录规则。
4. `docs/planning/项目计划书.md`、`docs/planning/里程碑规划.md` —— 范围与里程碑。
5. `ai/实现提示词.md` 对应里程碑段落 + `docs/operations/任务清单.md` 对应条目。
6. 涉及配置字段时：`docs/services/配置字段说明.md`（统一配置权威字段表）与 `docs/architecture/架构与决策记录.md` 的 ADR-007。

## 3. 不可更改的架构约束（违反即打回）

- **方案A**：一服务一独立 MCP Server 进程（`mcp-gerrit/`、`mcp-github/`、`mcp-jenkins/`、`mcp-atlassian/`），禁止聚合单体。
- 总控必须是 PowerShell 全中文菜单脚本；路径全部仓库相对定位；面向 Windows。
- stdio 本地按需拉起为主形态；不使用远程托管 MCP 端点作为主路径。
- **Jenkins 零侵入**：只通过 REST API + API Token 调用，不安装插件、不改实例配置。
- 依赖仓库内隔离：各子服务自持 venv / node_modules 与锁定文件；不污染系统全局 Python/Node。
- **真实凭证绝不入库**：仓库只保留统一配置模板 `mcp.config.sample.json`（参考值 + `_hints` 中文提示）与 `mcp.config.schema.json`；真实配置为仓库根 `mcp.config.json`（已 gitignore）。
- **配置集中（ADR-007）**：四个服务的运行配置只放在仓库根 `mcp.config.json`，按 `services.<key>` 分段；禁止在服务目录新建配置文件（依赖清单仍在各服务目录）。新增或调整字段须同步 sample、Schema、`docs/services/配置字段说明.md`，并保证 CI 的模板与 Schema 校验通过。
- 写操作（投票、写评论、改 reviewer、触发构建等）保留**二次确认**闸门，优先只读模式。
- 交互、菜单、提示、日志文案全中文（技术名词除外）。

## 4. 里程碑流程（严格顺序）

依赖链：`M0 → M1 → {M2→M5, M3→M6, M4→M7、M8}`，`M3 → M9`，`M5–M9 → M10`。

- **一次只承接一个里程碑**；前一里程碑 PR 合并入 main 后才能开始下一个。
- 每里程碑一个 Issue：标题 `[M<n>] <里程碑名称>`，打 `m<n>` 标签并关联同名 GitHub Milestone。
- 里程碑完成即翻牌 `docs/operations/任务清单.md` 对应条目（回填 Issue/PR；状态按下面的口径判定）。
- 任务状态口径：「已完成」只用于交付物已形成且验收通过的任务（负责人已确认，或交付物带 CI 强制校验且持续通过）；纯文档产出在负责人确认前记「待验收」并在验收标准末尾备注交付物形态（见 `docs/00-文档管理规范.md` §8.2）。
- 合并前自检 `ai/实现提示词.md` 第三节检查点（范围、凭证、CI、文档同步、中文提示等）。
- M5–M8 服务接入一律参照第 8 节「本地参考实现」，锁定版本后再实现。

## 5. 交付流程（GitHub Flow）

- `main` 受分支保护：required check=`checks`（CI）、0 审批人、仅 Squash Merge、禁直推、禁强推。
- 分支命名：`feat|fix|chore|docs/<模块>-<简述>`。
- 提交信息：Conventional Commits，`<type>(<scope>): <中文摘要>`；scope ∈ `mcpctl|gerrit|github|jenkins|atlassian|docs`。
- PR：按 `.github/PULL_REQUEST_TEMPLATE.md` 输出完整回执，正文含 `Closes #N`；CI 通过后 squash 合并；合并后删除远端分支。
- 标签三套：里程碑 `m0…m10`；`service:gerrit|github|jenkins|atlassian`、`area:mcpctl|docs`；`kind:feat|bug|chore|docs`。

## 6. 文档管控（违反规范 PR 不予合并）

- 新文档流程：`docs/01-文档台账.md` 申请编号 → 按已登记目录落位 → 补头部属性表（L2/L3/L5/L6 必填）→ 文末追加变更记录。
- 编号规则：工程文档 `DOC-<域>-<序号>`、AI 文档 `AI-<域>-<序号>`；一经分配不复用。
- L4 记录类（任务清单/问题记录/更新记录）**只追加、不改写历史**。
- 每次合并入库后在 `docs/operations/更新记录.md` 追加条目（版本倒序）。
- 目录只能使用 `docs/00-文档管理规范.md` §3.3 已登记域目录；确需新目录先补登规范再建。
- 版本语义化（v主.次.修）；状态流转 D → R → A；变更必记变更记录并同步台账。
- 合并前运行 `scripts/lib/ledger-audit.ps1`（CI 同款）：台账 ↔ 文内编号 / 版本 / 状态 / 日期一致；结论未回填的验收记录不得标 `生效（A）`（只能是 `评审中（R）`）。

## 7. 安全红线

- 真实 Token / 密码 / HTTP 凭证 / 内部地址不写入仓库、日志、对话输出。
- 凭证只写入本地被 `.gitignore` 排除的统一配置文件 `mcp.config.json`（仅本机可读，禁止网盘/邮件同步）；Host 配置只放 `env.MCP_SUITE_CONFIG` 路径，不放凭证。
- 保持 CI 阻断能力：统一配置入库检查（`mcp.config.json` 被跟踪即失败）、模板与 Schema 校验、注册表自检、依赖产物跟踪检查、gitleaks 密钥扫描（PR 事件需 checkout `fetch-depth: 0` 且显式传 `GITHUB_TOKEN`）。
- 服务账号最小权限，优先只读；写操作二次确认。
- 曾在任何渠道暴露的凭证立即在对应系统重置，并在 `docs/operations/问题记录.md` 登记（先例 DEV-001）。

## 8. 本地参考实现（M5–M8 照此落地）

参考位置 `D:\zeek\AiData\MCP`（已配置、实测可用；凭证只存其本地 `credentials.env`，不在仓库）：

| 服务 | 技术路线 | 关键要点 |
|---|---|---|
| mcp-jenkins | npm 包 `jenkins-mcp-server@^1.0.3`，`node_modules` 本地化 | `launcher.mjs` 先读 `credentials.env` 注入 env，再**动态 `await import()`** 上游入口（静态 import 会被提升、先于 credentials.env 执行，触发 validateConfig `exit(1)`）；env：`JENKINS_URL`、`JENKINS_USERNAME`、`JENKINS_API_TOKEN` |
| mcp-github | 官方 Go 单二进制 `github-mcp-server.exe`（GitHub Releases `Windows_x86_64.zip`） | v2.x 必须显式 `stdio` 子命令；`--read-only`、`--toolsets` 控制能力面；env：`GITHUB_PERSONAL_ACCESS_TOKEN` |
| mcp-atlassian | Python venv + `pip install mcp-atlassian==<锁定版本>` | stdio 或常驻 HTTP（`127.0.0.1:9111/mcp`，streamable-http）；PAT 存 `credentials.env`；Jira/Confluence 同进程双命名空间 |

已知坑（复用时先查）：
- Windows 商店 `python` stub 返回 9009 —— 必须用各子服务 `venv\Scripts\python.exe`。
- 凭证只进 `credentials.env`，绝不写进 Host 配置文件（mcp.json 等）。
- 重复拉起常驻进程会锁日志文件；先查 PID/端口再启动。
- PowerShell 中文注释/输出保存为 **UTF-8 with BOM**，避免 Windows PowerShell 5.1 乱码。

连通测试授权（仓库维护人 2026-11-25 批准）：M5–M8 允许使用上述已配置凭证执行**只读探活**，并把「已验证版本 / 实际工具集 / 已知限制」回填 `docs/services/服务接入说明.md`；凭证绝不入库、绝不写入对话或日志。

## 9. 脚本与工程约定

- PowerShell：文件 UTF-8 with BOM；`$ErrorActionPreference = 'Stop'`；中文提示；提交前本地跑与 CI 同款 `[System.Management.Automation.Language.Parser]::ParseFile` 语法自检。
- Python：仅使用各子服务目录内 venv 解释器；依赖锁定（requirements 锁定版本）。
- Node：`node_modules` 固定在各子服务目录内；锁定文件（package-lock.json）入库。
- 临时/中间脚本一律放在**仓库外**工作区临时目录，绝不提交进仓库。
- 交互脚本防输入结束空转：`Read-Host` 返回 `$null`（标准输入已到末尾）即提示并退出，不得落入默认动作；`Read-Host -AsSecureString` 在标准输入被重定向时会永久阻塞，读取敏感字段前先判断 `[Console]::IsInputRedirected`。
- 启动器约定：stdout 只输出 MCP 协议，诊断信息与中文报错写 stderr，失败时退出码非 0；统一读取环境变量 `MCP_SUITE_CONFIG`（未设置时回退服务目录上一级的 `mcp.config.json`），占位符或缺少配置段时拒启。
- 提交消息与 Issue / PR 正文先写成 UTF-8 文件，再用 `git commit -F`、`gh … --input` 提交（中文弯引号会被命令行当作参数定界符）。

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v1.0.0 | 2026-11-25 | zeek.zhao | 首次建立仓库定义性开发技能文件 | 固化开发流程与约束（Issue #3） |
| v1.1.0 | 2026-11-26 | zeek.zhao | §3 新增配置集中约束并修订模板口径；§7 安全红线与 CI 口径同步；§9 补输入结束保护、启动器与提交约定；§2 补配置字段说明 | 统一配置改造（ADR-007，T-DOC-01，Issue #57） |
| v1.2.0 | 2026-11-26 | zeek.zhao | §6 新增合并前台账审计要求（scripts/lib/ledger-audit.ps1，CI 同款；结论未回填的验收记录不得标生效（A）） | 验收文档状态纠正（T-FIX-G，Issue #75） |
| v1.3.0 | 2026-11-26 | zeek.zhao | §4 新增任务状态口径（「已完成」仅用于交付物已形成且验收通过的任务；纯文档产出在负责人确认前记待验收） | 小口径与洁净度（T-FIX-J，Issue #79） |
