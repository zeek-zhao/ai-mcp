# 新增 MCP 服务工作流

| 文档编号 | DOC-PLAN-003 |
|---|---|
| 文档名称 | 新增 MCP 服务工作流 |
| 版本 | v1.1.0 |
| 状态 | 生效（A） |
| 密级 | 内部 |
| 作者 | zeek.zhao |
| 创建日期 | 2026-11-26 |
| 最后更新 | 2026-11-26 |
| 关联里程碑 | M5–M10、环境变量与工作流 |
| 评审人 | 自审 |
| 存放路径 | `docs/planning/新增MCP服务工作流.md` |

> 适用范围：在本仓库新增一个由 Host 按需拉起的 stdio MCP 服务（ADR-006），配置集中写在仓库根 `mcp.config.json`（ADR-007）。
> 本文规定每一步的目的、操作、完成判据与涉及文件。CI 的「新增服务一致性检查」按第 2–9 步逐项核对，漏掉哪一处都会在 CI 里指出。
> 不变量：真实凭证不入库；stdout 只写 MCP 协议；依赖清单留在各服务目录；一个 Issue 对应一个 PR。

## 1. 流程总览

| 步骤 | 名称 | 脚手架能否代劳 | 一致性检查是否覆盖 |
|---|---|---|---|
| 1 | 选型与上游评估 | 否（记录在 Issue） | 否 |
| 2 | 目录与依赖锁版本 | 是（生成骨架与依赖清单） | 是 |
| 3 | 启动器映射 | 部分（生成带配置校验的模板） | 是（文件存在） |
| 4 | 注册表 | 否（脚手架打印条目片段） | 是 |
| 5 | 统一配置（模板、Schema、字段说明） | 否 | 是 |
| 6 | 配置向导字段目录 | 否 | 是 |
| 7 | 网关样例与服务名 | 否 | 是 |
| 8 | 自检用例 | 否 | 是 |
| 9 | 文档与台账 | 否 | 是（服务接入说明小节） |
| 10 | CI 全绿与干净环境验证 | 否 | CI 本身 |

约定：

- 服务 Id 形如 `mcp-<名称>`（小写字母、数字、连字符），同时是服务目录名；配置段名（`ConfigKey`）默认取 Id 去掉 `mcp-` 前缀。
- 一个服务一条 Issue（模板：`.github/ISSUE_TEMPLATE/new-service.yml`），对应一个 PR；提交信息遵循 Conventional Commits。
- 演示模式（`-Demo`）只用于把流程走通，接入真实上游前必须替换启动器里的演示服务。

## 2. 十个步骤

### 第 1 步：选型与上游评估

- **目的**：接入前确认上游可用、可锁版本、凭证可按需获取，避免做到一半才发现不支持 stdio 或无法只读。
- **操作**：
  1. 记录上游项目名、版本号、许可证、传输方式（必须支持 stdio）、运行时（Python / Node / 二进制）。
  2. 记录上游要求的凭证类别与获取方式（只写类别与获取路径，不写值）。
  3. 确认上游有可用于自检的只读调用（供第 8 步使用），并了解其写操作是否有只读开关。
  4. 把以上内容填进 Issue 的「上游评估」栏。
- **完成判据**：Issue 中能查到上游名称、版本、传输方式、凭证类别、可用作自检的只读调用。
- **涉及文件**：无（Issue）。

### 第 2 步：目录与依赖锁版本

- **目的**：服务目录与依赖清单就位，`scripts/bootstrap.ps1` 能识别并初始化。
- **操作**：
  1. 运行脚手架：`scripts\new-mcp.ps1 -Id mcp-xxx -DisplayName 显示名 -Stack python|node [-ConfigKey 配置段] [-Demo]`。生成 `<Id>/launcher.py`（或 `launcher.mjs`）与依赖清单，并打印后续 6 处手工修改。脚手架不在服务目录生成 `README.md`：仓库内的 Markdown 须按《文档管理规范》登记台账，服务说明统一写在 `docs/services/服务接入说明.md`（第 9 步）。
  2. 在依赖清单写入上游包的锁定版本：Python 写 `包名==x.y.z`；Node 在 `package.json` 固定版本后生成锁文件（`npm install --package-lock-only`）。`bootstrap.ps1` 只做锁定安装（`npm ci`），没有锁文件不会安装。
  3. 运行 `scripts\bootstrap.ps1`（或菜单 5）初始化该服务的依赖环境；依赖目录与虚拟环境不入库。
- **完成判据**：
  - 目录名等于服务 Id；Python 服务有 `requirements.txt`，Node 服务有 `package.json` 与 `package-lock.json`。
  - `scripts\bootstrap.ps1 -Check` 的列表里有该服务；初始化后状态为「已就绪」。
- **涉及文件**：`scripts/new-mcp.ps1`、`<Id>/launcher.py|launcher.mjs`、`<Id>/requirements.txt|package.json|package-lock.json`。

### 第 3 步：启动器映射

- **目的**：启动器从统一配置读取 `services.<配置段>`，校验后按上游要求注入环境变量并拉起上游。
- **操作**（在脚手架生成的模板里改）：
  1. 补字段中文名（`LABELS` / `labels`），报错文案用「统一配置 services.<配置段>.<字段>（<中文名>）…」。
  2. 用 `require_filled` / `requireFilled` 校验全部必填字段（地址类带 `url=True` / `true`）；占位符与模板参考值一律拒启。
  3. 按上游要求注入环境变量（进程内 `os.environ` / `process.env`，或传给子进程），然后拉起上游，替换演示服务 `run_demo_server` / `runDemoServer`。
  4. 保留三级配置定位（`MCP_SUITE_CONFIG` > `MCP_SUITE_ROOT` > 脚本位置推断）与 `configVersion` 检查。
  5. 诊断信息只写 stderr；stdout 只写 MCP 协议；日志里不出现凭证与实例地址。
- **完成判据**：
  - 语法检查通过（`python -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" <Id>/launcher.py` 或 `node --check <Id>/launcher.mjs`）。
  - 以模板为配置启动：stderr 出现「仍是模板参考值」或「仍是占位符」且退出码为 1（`scripts\tests\run-tests.bat --structural` 中该服务为 SKIP）。
  - 以真实配置启动：`scripts\tests\run-tests.bat --service <Id>` 握手成功。
- **涉及文件**：`<Id>/launcher.py|launcher.mjs`；参考实现 `mcp-gerrit/launcher.py`、`mcp-jenkins/launcher.mjs`、`mcp-atlassian/launcher.py`。

### 第 4 步：注册表

- **目的**：`mcpctl` 与各脚本通过注册表找到服务，不在别处写死服务清单。
- **操作**：把脚手架打印的条目追加到 `scripts/mcpctl.config.ps1` 的 `$script:McpServices` 末尾，字段与对齐写法保持一致：

  ```powershell
      @{
          Code           = 'E'
          Id             = 'mcp-xxx'
          DisplayName    = '显示名'
          StartCommand   = @('mcp-xxx/venv/Scripts/python.exe', 'mcp-xxx/launcher.py')
          ConfigKey      = 'xxx'
          PidFile        = 'mcp-xxx/run.pid'
          LogFile        = 'mcp-xxx/logs/service.log'
          Stack          = 'python'
      }
  ```

  - `Code` 取下一个未占用的字母；`ConfigKey` 是统一配置里 `services` 下的段名，不得与已有服务重复。
  - `StartCommand` 约定：Python 服务用 `<Id>/venv/Scripts/python.exe` + `<Id>/launcher.py`；Node 服务用 `node` + `<Id>/launcher.mjs`；二进制服务用可执行文件名并补 `BinaryPath`。
- **完成判据**：注册表自检通过（CI「PowerShell 脚本语法解析」步骤输出「注册表自检通过」）；`scripts\mcpctl.ps1` 菜单 1 的诊断列表里有该服务。
- **涉及文件**：`scripts/mcpctl.config.ps1`。

### 第 5 步：统一配置（模板、Schema、字段说明）

- **目的**：新服务的配置字段进入唯一配置文件，并有结构校验与填写说明。
- **操作**：
  1. `mcp.config.sample.json` 的 `services` 中新增配置段（顺序与注册表一致）：必填项先写占位符 `<填写说明>`，地址类参考值带 `example.com` 字样，可选字段给默认值；并在 `_hints` 中为每个字段补一条中文提示。
  2. `mcp.config.schema.json`：`definitions` 中新增配置段的字段定义（`required` 与字段说明的「必填」列一致），并在 `definitions.services.properties` 中新增同名键（`$ref` 指向该定义）。
  3. `docs/services/配置字段说明.md` 的字段全表新增该服务的字段行（路径以 `services.<配置段>.` 开头，「必填」列为「是」或「否」）。
- **完成判据**：CI「统一配置模板与 Schema 校验」通过（每个字段有中文提示、Schema 必填集合与契约一致、模板参考值均被指纹覆盖）；「新增服务一致性检查」第 5 步无报错。
- **涉及文件**：`mcp.config.sample.json`、`mcp.config.schema.json`、`docs/services/配置字段说明.md`。

### 第 6 步：配置向导字段目录

- **目的**：`mcpctl` 菜单 4 能逐字段录入新服务的配置。
- **操作**：在 `scripts/lib/config-wizard.ps1` 的 `$script:McpSuiteFieldCatalog` 中新增 `<配置段> = @(...)`；字段集合与顺序必须与模板一致，否则进入向导时报错。`Kind` 取值：`bool` / `choice` / `url` / `text` / `secret` / `list` / `reserved`；敏感字段用 `secret`（录入时不回显）。
- **完成判据**：`scripts\mcpctl.ps1` 菜单 4 进入该服务时不出现「配置向导的字段目录与模板不一致」。
- **涉及文件**：`scripts/lib/config-wizard.ps1`。

### 第 7 步：网关样例与服务名

- **目的**：Magpie 网关模式（可选）下能经菜单 8 生成本机路由。
- **操作**：
  1. `scripts/lib/gateway-routes.ps1` 的 `$script:McpGatewayNames` 中新增 `'<Id>' = '<服务名>'`。
  2. `gateway.routes.sample.json` 的 `mcpServers` 中新增同名条目：`command` / `args` 与注册表 `StartCommand` 对应（路径以 `${MCP_SUITE_ROOT}` 开头），`env` 只含 `MCP_SUITE_CONFIG`。
- **完成判据**：CI「网关路由样例校验」与「网关路由生成器自检」通过；菜单 8 生成的文件与样例逐条一致。
- **涉及文件**：`scripts/lib/gateway-routes.ps1`、`gateway.routes.sample.json`。

### 第 8 步：自检用例

- **目的**：`scripts/tests/run-tests.bat` 能对新服务做握手、工具数与一次只读调用。
- **操作**：
  1. 复制 `scripts/tests/test-gerrit.bat` 为 `scripts/tests/test-<配置段>.bat`，把 `--service` 改为新服务 Id。`scripts/tests/run-tests.bat` 按用例文件逐个调用 `test-<配置段>.bat`，总入口不需要修改。
  2. `scripts/tests/cases/services.json` 的 `services` 中新增一条：`id`、`configKey`、`gatewayName`（与第 7 步一致）、`expectedTools`（实测值）、`readOnlyCall`（工具名与参数）。
  3. 用真实配置生成第一份工具快照：`scripts\tests\run-tests.bat --service <Id> --snapshot`，得到 `scripts/tests/tools-snapshot/<Id>.json` 并随 PR 提交（快照不含凭证与实例信息）。
- **完成判据**：`scripts\tests\run-tests.bat --service <Id>` 退出码 0；`scripts\tests\run-tests.bat --structural` 退出码 0（用例与注册表、模板、网关样例、启动器文件一致，快照工具数与 `expectedTools` 一致）；`scripts\tests\run-tests.bat --service <Id> --diff` 退出码 0。
- **涉及文件**：`scripts/tests/test-<配置段>.bat`、`scripts/tests/cases/services.json`、`scripts/tests/tools-snapshot/<Id>.json`；格式见 `docs/services/自检脚本说明.md`。

### 第 9 步：文档与台账

- **目的**：他人不读代码也能接入、验证与排错。
- **操作**：
  1. `docs/services/服务接入说明.md` 新增小节 `## <序号>. <Id>（显示名）`：配置段、前置条件、Host 配置、已知限制、验证状态。
  2. `docs/operations/任务清单.md` 登记任务；`docs/operations/更新记录.md` 在本 PR 追加版本段；`docs/01-文档台账.md` 同步版本；README 导航如需补充。
  3. 涉及架构取舍时在 `docs/architecture/架构与决策记录.md` 追加 ADR。
- **完成判据**：CI「文档台账一致性审计」通过；一致性检查第 9 步无报错。
- **涉及文件**：`docs/services/服务接入说明.md`、`docs/operations/任务清单.md`、`docs/operations/更新记录.md`、`docs/01-文档台账.md`。

### 第 10 步：CI 全绿与干净环境验证

- **目的**：证明新服务在别人机器上也能跑起来。
- **操作**：
  1. 推送分支并开 PR（引用对应 Issue）；等待 CI 全绿，重点看「新增服务一致性检查」「统一配置模板与 Schema 校验」「自检脚本结构模式（Windows）」。
  2. 在没有依赖目录的环境运行 `scripts\bootstrap.ps1` 初始化，再运行 `scripts\tests\run-tests.bat --service <Id>`。
  3. 用真实凭证做一次只读调用，结果写入验收记录的「执行记录」；结论由负责人回填。
- **完成判据**：PR 合并；干净环境下自检退出码 0；验收记录有执行记录。
- **涉及文件**：`.github/workflows/ci.yml`、`docs/operations/验收记录-*.md`。

## 3. 一致性检查覆盖范围

CI 步骤「新增服务一致性检查」以注册表为准，逐条服务核对下表；报错形如 `mcp-xxx（配置段 xxx）第 N 步未完成：<缺什么>`，多出未注册服务的配置段、用例或样例条目也会报错。

| 步骤 | 检查点 |
|---|---|
| 2 | 启动器位于 `<Id>/` 下；Python 有 `<Id>/requirements.txt`，Node 有 `<Id>/package.json` |
| 3 | 启动器文件存在 |
| 4 | 注册表条目的 Id、配置段、技术栈可解析 |
| 5 | 模板 `services` 有该配置段；Schema 两处落点齐全；配置字段说明有该服务的字段行 |
| 6 | 向导字段目录有该配置段 |
| 7 | `McpGatewayNames` 与网关样例 `mcpServers` 有该服务 |
| 8 | `scripts/tests/test-<配置段>.bat` 存在；用例的 id、configKey、gatewayName 一致（工具快照是否存在、快照工具数与 `expectedTools` 是否一致，由 CI「自检脚本结构模式」校验） |
| 9 | 服务接入说明有 `## <序号>. <Id>` 小节 |

## 变更记录

| 版本 | 日期 | 变更人 | 变更摘要 | 原因/关联条目 |
|---|---|---|---|---|
| v1.0.0 | 2026-11-26 | zeek.zhao | 首次建立新增 MCP 服务工作流：10 步（目的、操作、完成判据、涉及文件）、一致性检查覆盖范围 | 新增服务工作流（T-FLOW-01，Issue #95 / PR #96） |
| v1.1.0 | 2026-11-26 | zeek.zhao | 第 8 步增加生成第一份工具快照（`--snapshot`）与无差异判据（`--diff`）；覆盖范围表第 8 步注明快照校验所在步骤 | 升级 MCP 服务工作流（T-FLOW-02，Issue #97 / PR __PR__） |
