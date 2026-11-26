# 升级 MCP 服务工作流

| 文档编号 | DOC-PLAN-004 |
|---|---|
| 文档名称 | 升级 MCP 服务工作流 |
| 版本 | v1.0.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-26 |
| 最后更新 | 2026-11-26 |
| 关联里程碑 | M5–M10、环境变量与工作流 |
| 评审人 | 自审 |
| 存放路径 | `docs/planning/升级MCP服务工作流.md` |

> 上游升版可能改工具名、删工具、加必填参数。升级 MCP 服务时按本文档的 8 步执行：**先对比、后更新**——用工具快照发现差异，把差异写进 PR，再更新用例、快照与文档。回滚路径见第 4 节。

---

## 1. 适用范围与约定

- 对象：各 MCP 服务的上游版本。Python 服务的锁定版本在 `<Id>/requirements.txt`；Node 服务在 `<Id>/package.json` 与 `<Id>/package-lock.json`。
- 一次只升级一个服务，开一个 Issue、一个 PR；版本变更与由此带来的用例、快照、文档更新放在同一个 PR。
- 工具数在三处必须一致：`scripts/tests/cases/services.json` 的 `expectedTools`、工具快照 `scripts/tests/tools-snapshot/<Id>.json` 的 `toolCount`、`docs/services/服务接入说明.md` 中的工具数。CI 的结构模式校验前两者。
- 快照与用例不含凭证与实例信息，可以入库；真实只读调用的结果只写进验收记录的「执行记录」。
- 基线：开始升级前，main 上该服务应满足 `scripts\tests\run-tests.bat --service <Id> --diff` 退出码 0（当前工具与快照无差异）。main 上的快照就是本次升级的对比基线，不必另存。

---

## 2. 流程总览

| 步骤 | 内容 | 完成判据 |
|---|---|---|
| 1 | 读上游 changelog / release notes，记录版本与变更点 | Issue 中有目标版本与变更点 |
| 2 | 改锁版本（`requirements.txt` / `package.json` + lock） | 差异只含版本与锁文件 |
| 3 | `scripts\bootstrap.ps1 -Rebuild` 重装该服务依赖 | 结果为「已创建」，检查为已就绪 |
| 4 | `run-tests.bat --diff` 对比升级前后的工具 | 拿到「新增 / 删除 / 签名变化」清单 |
| 5 | 差异处理：更新用例期望数并重新生成快照 | `--structural` 与 `--diff` 退出码 0 |
| 6 | 更新 `docs/services/服务接入说明.md` 的「已验证版本」与工具数 | 文档与实测一致 |
| 7 | 更新 `更新记录`、台账、任务清单 | CI「文档台账一致性审计」通过 |
| 8 | PR 描述附差异摘要，CI 校验 | CI 全绿后合并 |

---

## 3. 步骤说明

### 第 1 步：读上游 changelog / release notes

- **目的**：升级前知道上游改了什么，带着预期去看差异。
- **操作**：在升级 Issue 中记录目标版本、变更点，以及预计会受影响的工具（新增、删除、改名的工具；新增的必填参数）。
- **完成判据**：Issue 中有目标版本与变更点清单。
- **涉及文件**：无（记录在 Issue）。

### 第 2 步：改锁版本

- **目的**：把依赖固定到确定的新版本，保证别人机器上装到同一份代码。
- **操作**：
  1. 从 main 切升级分支。
  2. Python 服务：把 `<Id>/requirements.txt` 中对应的一行改成 `包名==新版本`，不放开版本范围。
  3. Node 服务：修改 `<Id>/package.json` 的版本号，在该目录运行 `npm install --package-lock-only` 更新 `package-lock.json`；不要提交 `node_modules`。
  4. 提交「版本提交」，说明目标版本与来源（changelog 链接写在 Issue 里即可）。
- **完成判据**：`git diff main` 中依赖相关的差异只有版本号与锁文件。
- **涉及文件**：`<Id>/requirements.txt` 或 `<Id>/package.json`、`<Id>/package-lock.json`。

### 第 3 步：重装该服务依赖

- **目的**：让本机的依赖目录与新的锁版本一致。
- **操作**：`scripts\bootstrap.ps1 -Rebuild -Code <服务代号>`（服务代号见 `scripts/mcpctl.config.ps1`；也可以在 `scripts\mcpctl.ps1` 的菜单 5 中选择重建）。
- **完成判据**：结果表中该服务为「已创建」；`scripts\bootstrap.ps1 -Check` 显示「已就绪」。
- **失败时**：例如版本号不存在，结果为「失败 依赖安装失败。下一步：检查网络与 requirements.txt 后重跑（或 -Rebuild 重建）」。回到第 2 步核对版本号与可用性，修正后**仍然用 `-Rebuild` 重跑**。安装失败后不要直接重跑不带 `-Rebuild` 的命令：已建好的环境会被判为「已就绪」而不再安装（DEV-019）。
- **涉及文件**：依赖目录不入库（`.gitignore` 已排除）。

### 第 4 步：对比升级前后的工具

- **目的**：用事实说明这次升级改了哪些工具，而不是只看工具数。
- **操作**：`scripts\tests\run-tests.bat --service <Id> --diff`。命令拉起新版本服务，把当前 `tools/list` 与 main 上的快照比较。有差异时退出码为 1，这是本步骤的预期结果。
- **完成判据**：拿到三段清单（新增 / 删除 / 签名变化）；该输出原样留作 PR 描述的摘要。
- **输出示例**（一次差异演示的实测输出）：

  ```text
  [mcp-gerrit] 工具快照差异（mcp-gerrit）：新增 1 / 删除 1 / 签名变化 1
  [mcp-gerrit]   新增：suggest_reviewers
  [mcp-gerrit]   删除：zz_removed_tool
  [mcp-gerrit]   签名变化：query_changes（必填字段 快照 [] → 当前 [query]（新增 query）；参数 快照 3 个 → 当前 4 个（新增 options））
  ```

- **拉不起服务时**：退出码为 2（BLOCKED），输出会给出启动器的报错原文，例如「上游服务缺失」（第 3 步没有安装成功）。先解决环境问题，再回到本步骤。
- **涉及文件**：`scripts/tests/tools-snapshot/<Id>.json`（只读）。

### 第 5 步：差异处理

- **目的**：把上游的变化落实到用例、快照与已知问题记录，避免提示词与流程静默失效。
- **操作**：按差异类型处理，然后更新用例与快照。

  | 差异类型 | 处理 |
  |---|---|
  | 新增工具 | 评估是否需要对外暴露；工具数相应更新 |
  | 删除或改名 | 更新 `docs/services/服务接入说明.md` 中对该工具的引用；用例的 `readOnlyCall` 若用到被删工具，改用仍然存在的只读工具；导致既有提示词或流程失效时在 `docs/operations/问题记录.md` 登记 DEV |
  | 签名变化（新增必填参数、参数改名） | 检查用例 `readOnlyCall` 的参数是否仍可用；检查文档中的调用示例 |
  | 仅说明变化 | 一般无需处理，在 PR 描述中带过即可 |

  1. 把 `scripts/tests/cases/services.json` 中该服务的 `expectedTools` 改为实测值。
  2. `scripts\tests\run-tests.bat --service <Id> --snapshot` 重新生成快照（覆盖旧快照）。
  3. `scripts\tests\run-tests.bat --structural` 确认用例、快照、注册表一致。
- **完成判据**：`scripts\tests\run-tests.bat --service <Id> --diff` 退出码 0（新快照与新版本一致）；`scripts\tests\run-tests.bat --service <Id>` 退出码 0（握手、工具数、只读调用）。
- **涉及文件**：`scripts/tests/cases/services.json`、`scripts/tests/tools-snapshot/<Id>.json`、`docs/services/服务接入说明.md`、必要时 `docs/operations/问题记录.md`。

### 第 6 步：更新服务接入说明

- **目的**：文档里的「已验证版本」与工具数和实际一致。
- **操作**：更新 `docs/services/服务接入说明.md` 中该服务的「已验证版本」、工具数、已知限制（上游 changelog 中提到的限制一并补记）。用真实配置做了只读验证的，把结果写进验收记录的「执行记录」，结论由负责人回填。
- **完成判据**：文档中的版本与工具数等于第 5 步的实测值。
- **涉及文件**：`docs/services/服务接入说明.md`、`docs/operations/验收记录-*.md`。

### 第 7 步：更新记录、台账、任务清单

- **目的**：升级有迹可循，台账版本不漂移。
- **操作**：`docs/operations/更新记录.md` 追加版本段；`docs/01-文档台账.md` 同步本次改到的文档版本；`docs/operations/任务清单.md` 登记升级任务。
- **完成判据**：CI「文档台账一致性审计」通过。
- **涉及文件**：`docs/operations/更新记录.md`、`docs/01-文档台账.md`、`docs/operations/任务清单.md`。

### 第 8 步：PR 描述与 CI 校验

- **目的**：工具数剧变时，评审人能在 PR 里直接看到差在哪。
- **操作**：
  1. PR 描述粘贴第 4 步的输出（保留「工具快照差异」字样与三段清单），并写明第 5 步的处理结论。
  2. CI 步骤「PR 工具数变化校验」比较 PR 与基线的 `expectedTools`：变化幅度超过 ±20%（恰等于 20% 不算超过）时，描述中必须出现「工具快照差异」字样，否则该步骤失败并给出提示；未超过阈值或工具数未变化时直接通过。
  3. CI 全绿后合并。
- **完成判据**：PR 合并；main 上 `scripts\tests\run-tests.bat --service <Id> --diff` 退出码 0。
- **涉及文件**：`.github/workflows/ci.yml`、`scripts/tests/lib/check-pr-tool-diff.mjs`。

---

## 4. 回滚路径

升级合入后发现问题，按下面三步回滚（新开 PR，不强推、不改写 main 历史）：

1. **回退版本提交**：`git revert <版本提交>`。Squash 合并的 PR 回退该 PR 的合并提交即可；回退后锁文件、用例期望数与工具快照一并回到升级前。
2. **重建依赖**：`scripts\bootstrap.ps1 -Rebuild -Code <服务代号>`。必须带 `-Rebuild`，否则已存在的依赖目录不会被重装（DEV-019）。
3. **重跑快照对比**：`scripts\tests\run-tests.bat --service <Id> --diff` 退出码 0（当前工具与还原后的快照一致），再跑 `scripts\tests\run-tests.bat --service <Id>` 退出码 0。

升级进行到一半失败（第 3 步安装失败或第 4 步拉不起服务）：把锁文件改回原版本，`-Rebuild` 重建，然后重跑 `--diff` 确认无差异。不要把装不上的版本留在分支里提交。

---

## 5. CI 规则小结

| 检查 | 时机 | 规则 |
|---|---|---|
| 自检脚本结构模式 | 每次 push 与 PR | 每个用例都有快照；快照工具数与 `expectedTools` 一致；工具名不重复 |
| PR 工具数变化校验 | 仅 PR | `expectedTools` 相对基线变化超过 ±20% 时，PR 描述须含「工具快照差异」；基线没有的服务视为新增服务，不要求摘要；读不到基线提交时步骤失败 |

---

## 6. 演练记录

2026-11-26 对 Gerrit 服务做了一次「假升级」演练（在仓库外的副本中进行，使用本机真实配置，输出不含凭证与实例地址）：

| 步骤 | 操作 | 结果 |
|---|---|---|
| 基线 | `bootstrap.ps1 -Code A`；`run-tests.bat --service gerrit --diff` | 安装成功；对比无差异（新增 0 / 删除 0 / 签名变化 0），退出码 0 |
| 假升级 | 把 `requirements.txt` 中上游包的锁定版本改为不存在的版本；`bootstrap.ps1 -Rebuild -Code A` | 退出码 1，结果表为「失败 依赖安装失败。下一步：检查网络与 requirements.txt 后重跑（或 -Rebuild 重建）」 |
| 发现失败 | `run-tests.bat --service gerrit --diff` | 退出码 2（BLOCKED）：启动器报「上游服务缺失」并退出，自检明确指出环境未就绪，没有带着坏环境去做对比 |
| 回滚 | 还原锁版本；`bootstrap.ps1 -Rebuild -Code A` | 退出码 0，重新安装成功 |
| 复核 | `run-tests.bat --service gerrit --diff`；`run-tests.bat --service gerrit` | 对比无差异；直连自检通过（工具数 20、只读调用成功），退出码 0 |

结论：流程能在第 3 步发现失败并给出下一步，回滚三步后恢复到与快照一致的状态。快照对比对「删除了 1 个工具」「工具新增 1 个必填参数」的识别见第 4 步的输出示例；PR 描述校验的正反例见 `docs/services/自检脚本说明.md` 第 6 节。

---

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v1.0.0 | 2026-11-26 | zeek.zhao | 首次建立升级 MCP 服务工作流：8 步（目的、操作、完成判据、涉及文件）、差异处理表、回滚路径、CI 规则与演练记录 | 升级服务工作流（T-FLOW-02，Issue #97 / PR #98） |
