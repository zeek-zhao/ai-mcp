# 交付与 PR 规范

| 文档编号 | AI-GOV-001 |
|---|---|
| 文档名称 | 交付与 PR 规范 |
| 版本 | v1.0.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-25 |
| 最后更新 | 2026-11-25 |
| 关联里程碑 | M0–M10 |
| 存放路径 | `ai/交付与PR规范.md` |

## 1. 分支模型（GitHub Flow）

- `main` 为受保护主干，始终保持可运行、文档完整。
- 功能分支命名：
  - `feat/<模块>-<简述>`
  - `fix/<简述>`
  - `chore/<简述>`
  - `docs/<简述>`
- 从最新 `main` 切分支；不在 `main` 上直接提交。

## 2. Commit 规范（Conventional Commits）

格式：`<type>(<scope>): <中文摘要>`

- type：`feat` 新功能 / `fix` 修复 / `chore` 构建脚本杂项 / `docs` 文档 / `refactor` 重构 / `test` 测试。
- scope：模块或服务，如 `mcpctl`、`gerrit`、`github`、`jenkins`、`atlassian`、`docs`。
- 摘要简洁中文；提交信息中不得包含凭证。

## 3. Issue 与标签

- 每个里程碑先拆 Issue，类型对应 `.github/ISSUE_TEMPLATE/` 模板。
- 标签三类：
  - 里程碑：`m0` … `m10`
  - 服务/区域：`service:gerrit`、`service:github`、`service:jenkins`、`service:atlassian`、`area:mcpctl`、`area:docs`
  - 类型：`kind:feat`、`kind:bug`、`kind:chore`、`kind:docs`
- PR 中通过 `Closes #<编号>` 关联 Issue。

## 4. PR 流程

1. 从最新 `main` 切分支，完成后提 PR 到 `main`。
2. PR 按模板填写：关联 Issue、变更类型、变更内容、自测清单、风险点、证据（日志/截图）。
3. PR 必须说明：是否涉及凭证文件、是否需要更新文档、是否变更配置模板。
4. 合并前必须通过 CI；评审通过后合并，优先 Squash Merge。
5. 不得提交真实凭证、本地配置、日志、PID、虚拟环境/依赖目录。

## 5. 文档同步要求

- 涉及配置项/参数变更：同步 `docs/services/服务接入说明.md`。
- 新增/变更文档：按 `docs/00-文档管理规范.md` 更新台账、属性表、变更记录。
- 任务状态更新到 `docs/operations/任务清单.md`；问题登记到 `docs/operations/问题记录.md`；变更摘要登记到 `docs/operations/更新记录.md`。

## 6. 禁止事项

- 禁止直接 push 到 `main`。
- 禁止预留未完成的“占位业务逻辑”混入主流程。
- 禁止引入计划书未列出的外部托管服务依赖。
- 禁止在代码、注释、日志、提交、文档中写入真实凭证或内部敏感地址。

## 7. 自检清单（PR 提交前）

- [ ] 分支命名与 Commit 规范符合要求。
- [ ] 关联 Issue 与里程碑标签正确。
- [ ] 变更范围限定在当前里程碑/任务内。
- [ ] 无凭证/本地运行产物被提交。
- [ ] CI 通过；密钥扫描无告警。
- [ ] 相关文档与记录已同步更新。
- [ ] 回执模板已按 `ai/实现提示词.md` 第四节填写。

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v1.0.0 | 2026-11-25 | zeek.zhao | 首次建立交付与 PR 规范 | 项目初始化 |
