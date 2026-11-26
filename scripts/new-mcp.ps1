#Requires -Version 5.1
<#
.SYNOPSIS
    新增 MCP 服务脚手架（T-FLOW-01）。

.DESCRIPTION
    按 docs/planning/新增MCP服务工作流.md 的第 2、3 步生成服务目录骨架：
    启动器模板与依赖清单。
    启动器模板已实现与本仓库其他启动器一致的配置定位（MCP_SUITE_CONFIG > MCP_SUITE_ROOT > 脚本位置推断）
    与模板值 / 占位符拒绝逻辑；接入真实上游所需的映射留有 TODO 标记。

    本脚本只生成新目录内的文件，不修改任何已有文件。
    其余 6 处手工修改（注册表、sample、schema、配置向导字段目录、网关样例、自检用例）只打印清单。

.PARAMETER Id
    服务目录名，形如 mcp-xxx（小写字母、数字与连字符；mcp- 前缀必填）。

.PARAMETER DisplayName
    服务显示名称（中文，出现在注册表与菜单）。

.PARAMETER Stack
    技术栈：python（venv + requirements.txt）或 node（package.json + package-lock.json）。

.PARAMETER ConfigKey
    统一配置中的配置段名（services.<ConfigKey>）。省略时取 Id 去掉 mcp- 前缀。

.PARAMETER Demo
    生成自带只读演示工具的启动器（python 需要 mcp==1.30.0；node 不依赖任何包），
    用于在没有真实上游时走通「注册 → Bootstrap → 握手 → 自检」全流程。
    不带 -Demo 时启动器只做配置校验，随后提示「尚未接入上游」并退出。

.PARAMETER Force
    目标目录已存在时仍然生成（只覆盖本脚手架生成的文件：启动器与依赖清单）。

.EXAMPLE
    pwsh -NoProfile -File scripts\new-mcp.ps1 -Id mcp-demo -DisplayName '演示服务' -Stack python -Demo

.EXAMPLE
    pwsh -NoProfile -File scripts\new-mcp.ps1 -Id mcp-gitlab -DisplayName 'GitLab' -Stack node
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^mcp-[a-z0-9]+(-[a-z0-9]+)*$')]
    [string]$Id,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('python', 'node')]
    [string]$Stack,

    [ValidatePattern('^[a-z][a-z0-9]*$')]
    [string]$ConfigKey = '',

    [switch]$Demo,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'lib\registry.ps1')

# ---------------------------------------------------------------------------
# 启动器模板：单引号 here-string，占位符在生成时替换（$ 不被 PowerShell 展开）
#   __ID__ / __KEY__ / __DISPLAY__ / __DATE__ / __DEMO_FUNCTION__ / __RUN_BODY__
# ---------------------------------------------------------------------------

$script:McpScaffoldPythonDemoFunction = @'
def run_demo_server(section: dict) -> None:
    """演示用最小 MCP 服务（只读）。接入真实上游时删除本函数，改为拉起上游进程。"""
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        fail("演示服务依赖 mcp==1.30.0 未安装。下一步：运行 scripts/bootstrap.ps1 初始化依赖环境。")

    server = FastMCP(LABEL)

    @server.tool()
    def demo_echo(text: str) -> str:
        """把输入原样返回（演示用，只读）。"""
        return text

    @server.tool()
    def demo_config_fields() -> str:
        """列出本服务配置段中已设置的字段名，不返回字段值（演示用，只读）。"""
        names = sorted(
            key for key, value in section.items()
            if key != "enabled" and value not in (None, "", [], {})
        )
        return ", ".join(names)

    server.run(transport="stdio")


'@

$script:McpScaffoldPythonLauncher = @'
#!/usr/bin/env python3
"""__DISPLAY__ 启动器（__ID__）。

由 scripts/new-mcp.ps1 于 __DATE__ 生成，可自由修改。流程见 docs/planning/新增MCP服务工作流.md。

配置定位（与本仓库其他启动器一致）：
  1) 环境变量 MCP_SUITE_CONFIG（统一配置文件的绝对路径）
  2) 环境变量 MCP_SUITE_ROOT（仓库根目录）/ mcp.config.json
  3) 本文件所在目录的上一级（仓库根）/ mcp.config.json
启动器只做三件事：读取统一配置 services.__KEY__ 段 → 校验 → 拉起服务。
安全约束：不在本文件写入真实凭证；标准输出只留给 MCP 协议，提示一律写标准错误。
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

KEY = "__KEY__"
LABEL = "__DISPLAY__"
HERE = Path(__file__).resolve().parent
ROOT_ENV_NAME = "MCP_SUITE_ROOT"
ROOT_CLEAR_COMMAND = 'setx MCP_SUITE_ROOT ""'
CONFIG_NAME = "mcp.config.json"
# 模板参考值指纹：与 scripts/lib/suite-config.ps1 的 $script:McpSuiteTemplateValuePattern 保持一致
TEMPLATE_VALUE_PATTERN = re.compile(r"example\.com|example\.net|yourcompany|zhangsan|your-name|your-company", re.IGNORECASE)

# 字段中文名：按统一配置 services.__KEY__ 的实际字段增删（第 3 步）
LABELS = {
    "enabled": "是否启用__DISPLAY__",
    "baseUrl": "服务地址",
    # TODO(第 3 步)：例如 "apiToken": "API 令牌",
}


def fail(message: str) -> None:
    try:
        sys.stderr.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    sys.stderr.write(f"[__KEY__-launcher] {message}\n")
    sys.stderr.flush()
    raise SystemExit(1)


def is_placeholder_text(value: str) -> bool:
    text = value.strip()
    return text.startswith("<") and text.endswith(">")


def unfilled_text(value) -> str:
    """返回「未填写 / 占位符 / 模板参考值」的说明；已填写返回空串。不回显字段值。"""
    if value is None or not str(value).strip():
        return "未填写，请填写"
    text = str(value)
    if is_placeholder_text(text):
        return "仍是占位符，需填写真实值"
    match = TEMPLATE_VALUE_PATTERN.search(text)
    if match:
        return f"仍是模板参考值（特征：{match.group(0).lower()}），需替换为真实值"
    return ""


def root_issue(root_env: str):
    """MCP_SUITE_ROOT 已设置但无效时返回中文说明，否则返回 None（无效时不回退）。"""
    if not root_env:
        return None
    if not os.path.isabs(root_env):
        return f"环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：{root_env}。请改为正确的仓库根目录，或清除该变量后重试：{ROOT_CLEAR_COMMAND}"
    if not os.path.isfile(os.path.join(root_env, "scripts", "mcpctl.config.ps1")):
        return f"环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：{root_env}。请改为正确的仓库根目录，或清除该变量后重试：{ROOT_CLEAR_COMMAND}"
    return None


def resolve_config_path() -> Path:
    override = os.environ.get("MCP_SUITE_CONFIG", "").strip()
    if override:
        return Path(override)
    root_env = os.environ.get(ROOT_ENV_NAME, "").strip()
    issue = root_issue(root_env)
    if issue:
        fail(issue)
    if root_env:
        return Path(root_env) / CONFIG_NAME
    return HERE.parent / CONFIG_NAME


def load_section() -> dict:
    config_path = resolve_config_path()
    try:
        text = config_path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        fail(f"统一配置文件不存在：{config_path}。请复制 mcp.config.sample.json 为 mcp.config.json 后填写。")
    except OSError as exc:
        fail(f"统一配置文件无法读取：{config_path}（{type(exc).__name__}）。")
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        fail(f"统一配置文件不是合法 JSON：{config_path}。请检查引号、逗号与括号是否成对。")
    if not isinstance(doc, dict):
        fail(f"统一配置文件不是 JSON 对象：{config_path}")
    version = doc.get("configVersion")
    if version != 1:
        fail(f"统一配置的 configVersion 不受支持：{config_path}（当前仅支持 1）")
    services = doc.get("services")
    section = services.get(KEY) if isinstance(services, dict) else None
    if not isinstance(section, dict):
        fail(f"统一配置缺少 services.{KEY} 配置段：{config_path}")
    return section


def require_filled(section: dict, name: str, url: bool = False) -> str:
    value = section.get(name)
    issue = unfilled_text(value)
    if issue:
        fail(f"统一配置 services.{KEY}.{name}（{LABELS.get(name, name)}）{issue}。")
    text = str(value).strip()
    if url and not re.match(r"^https?://", text, re.IGNORECASE):
        fail(f"统一配置 services.{KEY}.{name}（{LABELS.get(name, name)}）必须是 http:// 或 https:// 开头的地址。")
    return text


__DEMO_FUNCTION__def main() -> None:
    section = load_section()
    if section.get("enabled") is not True:
        fail(f"服务已在统一配置中禁用（services.{KEY}.enabled=false）")

    base_url = require_filled(section, "baseUrl", url=True)
    # TODO(第 3 步)：校验其余必填字段并按上游要求注入环境变量，例如：
    #   token = require_filled(section, "apiToken")
    #   os.environ["DEMO_API_TOKEN"] = token
    _ = base_url

__RUN_BODY__

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # 未预期错误：只写类型名，不带配置内容
        fail(f"启动失败：{type(exc).__name__}。下一步：运行 scripts\\bootstrap.ps1 检查依赖环境")
'@

$script:McpScaffoldNodeDemoFunction = @'
function runDemoServer(section) {
  // 演示用最小 MCP 服务（只读），不依赖任何包。接入真实上游时删除本函数，改为拉起上游。
  const tools = [
    {
      name: "demo_echo",
      description: "把输入原样返回（演示用，只读）",
      inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
    },
    {
      name: "demo_config_fields",
      description: "列出本服务配置段中已设置的字段名，不返回字段值（演示用，只读）",
      inputSchema: { type: "object", properties: {} },
    },
  ];
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
  lines.on("line", (line) => {
    const raw = line.trim();
    if (!raw) return;
    let request;
    try {
      request = JSON.parse(raw);
    } catch {
      return;
    }
    const { id, method, params } = request;
    if (method === "initialize") {
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: params?.protocolVersion ?? "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: KEY, version: "0.0.0" },
        },
      });
    } else if (method === "tools/list") {
      send({ jsonrpc: "2.0", id, result: { tools } });
    } else if (method === "tools/call") {
      const name = params?.name;
      let resultText = "";
      if (name === "demo_echo") {
        resultText = `${params?.arguments?.text ?? ""}`;
      } else if (name === "demo_config_fields") {
        const names = Object.keys(section)
          .filter((key) => key !== "enabled" && section[key] !== "" && section[key] != null)
          .sort();
        resultText = names.join(", ");
      } else {
        send({ jsonrpc: "2.0", id, error: { code: -32602, message: `未知工具：${name}` } });
        return;
      }
      send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: resultText }], isError: false } });
    } else if (method === "ping") {
      send({ jsonrpc: "2.0", id, result: {} });
    } else if (id !== undefined) {
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: `不支持的方法：${method}` } });
    }
  });
  lines.on("close", () => process.exit(0));
}

'@

$script:McpScaffoldNodeLauncher = @'
#!/usr/bin/env node
// __DISPLAY__ 启动器（__ID__）。
// 由 scripts/new-mcp.ps1 于 __DATE__ 生成，可自由修改。流程见 docs/planning/新增MCP服务工作流.md。
//
// 配置定位（与本仓库其他启动器一致）：
//   1) 环境变量 MCP_SUITE_CONFIG（统一配置文件的绝对路径）
//   2) 环境变量 MCP_SUITE_ROOT（仓库根目录）/ mcp.config.json
//   3) 本文件所在目录的上一级（仓库根）/ mcp.config.json
// 安全约束：不在本文件写入真实凭证；stdout 只留给 MCP 协议，提示一律写 stderr。

import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const KEY = "__KEY__";
const LABEL = "__DISPLAY__";
const here = dirname(fileURLToPath(import.meta.url));
const ROOT_ENV_NAME = "MCP_SUITE_ROOT";
const ROOT_CLEAR_COMMAND = 'setx MCP_SUITE_ROOT ""';
const CONFIG_NAME = "mcp.config.json";
// 模板参考值指纹：与 scripts/lib/suite-config.ps1 的 $script:McpSuiteTemplateValuePattern 保持一致
const TEMPLATE_VALUE_PATTERN = /(example\.com|example\.net|yourcompany|zhangsan|your-name|your-company)/i;

// 字段中文名：按统一配置 services.__KEY__ 的实际字段增删（第 3 步）
const LABELS = {
  enabled: "是否启用__DISPLAY__",
  baseUrl: "服务地址",
  // TODO(第 3 步)：例如 apiToken: "API 令牌",
};

function fail(message) {
  process.stderr.write(`[${KEY}-launcher] ${message}\n`);
  process.exit(1);
}

function text(value) {
  return `${value ?? ""}`.trim();
}

function isPlaceholder(value) {
  return /^\s*<.*>\s*$/.test(`${value ?? ""}`);
}

function unfilledText(value) {
  if (!text(value)) return "未填写，请填写";
  if (isPlaceholder(value)) return "仍是占位符，需填写真实值";
  const hit = TEMPLATE_VALUE_PATTERN.exec(`${value}`);
  if (hit) return `仍是模板参考值（特征：${hit[1].toLowerCase()}），需替换为真实值`;
  return "";
}

function rootIssue(rootEnv) {
  if (!rootEnv) return "";
  if (!isAbsolute(rootEnv)) {
    return `环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：${rootEnv}。请改为正确的仓库根目录，或清除该变量后重试：${ROOT_CLEAR_COMMAND}`;
  }
  if (!existsSync(join(rootEnv, "scripts", "mcpctl.config.ps1"))) {
    return `环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：${rootEnv}。请改为正确的仓库根目录，或清除该变量后重试：${ROOT_CLEAR_COMMAND}`;
  }
  return "";
}

function resolveConfigPath() {
  const override = text(process.env.MCP_SUITE_CONFIG);
  if (override) return override;
  const rootEnv = text(process.env[ROOT_ENV_NAME]);
  const issue = rootIssue(rootEnv);
  if (issue) fail(issue);
  if (rootEnv) return join(rootEnv, CONFIG_NAME);
  return join(here, "..", CONFIG_NAME);
}

function loadSection() {
  const configPath = resolveConfigPath();
  if (!existsSync(configPath)) {
    fail(`统一配置文件不存在：${configPath}。请复制 mcp.config.sample.json 为 mcp.config.json 后填写。`);
  }
  let doc;
  try {
    doc = JSON.parse(readFileSync(configPath, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    fail(`统一配置文件不是合法 JSON：${configPath}。请检查引号、逗号与括号是否成对。`);
  }
  if (doc.configVersion !== 1) {
    fail(`统一配置的 configVersion 不受支持：${configPath}（当前仅支持 1）`);
  }
  const section = doc.services?.[KEY];
  if (!section || typeof section !== "object" || Array.isArray(section)) {
    fail(`统一配置缺少 services.${KEY} 配置段：${configPath}`);
  }
  return section;
}

function requireFilled(name, value) {
  const issue = unfilledText(value);
  if (issue) fail(`统一配置 services.${KEY}.${name}（${LABELS[name] ?? name}）${issue}。`);
  return text(value);
}

__DEMO_FUNCTION__function main() {
  const section = loadSection();
  if (section.enabled !== true) {
    fail(`服务已在统一配置中禁用（services.${KEY}.enabled=false）`);
  }
  const baseUrl = requireFilled("baseUrl", section.baseUrl);
  if (!/^https?:\/\//i.test(baseUrl)) {
    fail(`统一配置 services.${KEY}.baseUrl（${LABELS.baseUrl}）必须是 http:// 或 https:// 开头的地址。`);
  }
  // TODO(第 3 步)：校验其余必填字段并按上游要求注入环境变量，例如：
  //   process.env.DEMO_API_TOKEN = requireFilled("apiToken", section.apiToken);

__RUN_BODY__
}

main();
'@

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

function Expand-McpScaffoldText {
    # 按占位符字典逐项替换（长键优先，避免前缀相同的占位符互相覆盖）
    param([string]$Text, [System.Collections.IDictionary]$Replace)
    $out = $Text
    foreach ($name in (@($Replace.Keys) | Sort-Object -Property Length -Descending)) {
        $out = $out.Replace([string]$name, [string]$Replace[$name])
    }
    return $out
}

function Get-McpScaffoldNextCode {
    # 取下一个未占用的服务代号（A、B、C…）
    param([string[]]$UsedCodes)
    $used = @($UsedCodes | ForEach-Object { "$_".ToUpperInvariant() })
    $n = 0
    while ($n -le 25) {
        $candidate = [string][char](65 + $n)
        if ($used -notcontains $candidate) { return $candidate }
        $n++
    }
    return ('S' + (1 + $used.Count))
}

function Write-McpScaffoldFile {
    # 生成文件：UTF-8 无 BOM（Python / Node 源码与 Markdown 均按无 BOM 读取）
    param([string]$Path, [string]$Content, [bool]$Overwrite)
    if ((Test-Path -LiteralPath $Path) -and -not $Overwrite) {
        throw ('文件已存在，未覆盖：{0}（确认后可用 -Force 重新生成）' -f $Path)
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-McpNewService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][ValidateSet('python', 'node')][string]$Stack,
        [string]$ConfigKey,
        [bool]$Demo,
        [bool]$Force
    )

    $root = Get-McpRepoRoot
    $services = @(Get-McpServices)
    $sameId = @($services | Where-Object { $_.Id -eq $Id })
    if ($sameId.Count -gt 0) {
        throw ('服务 {0} 已在注册表中，不能用脚手架重复生成（第 4 步已完成的条目不要重做）。' -f $Id)
    }
    $key = $ConfigKey
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Id.Substring(4) }
    $sameKey = @($services | Where-Object { $_.ConfigKey -eq $key })
    if ($sameKey.Count -gt 0) {
        throw ('配置段名 {0} 已被服务 {1} 占用，请用 -ConfigKey 指定其他名称。' -f $key, $sameKey[0].Id)
    }
    $code = Get-McpScaffoldNextCode -UsedCodes @($services | ForEach-Object { $_.Code })

    $targetDir = Join-Path $root $Id
    if (Test-Path -LiteralPath $targetDir) {
        if (-not $Force) {
            throw ('目录已存在：{0}（确认不是别的目录后，加 -Force 只覆盖脚手架文件）' -f $targetDir)
        }
        Write-Output ('提示：目录已存在，只覆盖脚手架生成的文件：{0}' -f $targetDir)
    }

    $isPython = ($Stack -eq 'python')
    $demoFunction = $(if ($isPython) { $script:McpScaffoldPythonDemoFunction } else { $script:McpScaffoldNodeDemoFunction })
    $launcherName = $(if ($isPython) { 'launcher.py' } else { 'launcher.mjs' })
    $depsName = $(if ($isPython) { 'requirements.txt' } else { 'package.json' })
    # main() 末尾的运行段：演示模式启动演示服务；非演示模式在完成配置校验后提示并退出
    $notWired = '启动器模板尚未接入上游：请在本文件 main() 中拉起真实服务（流程见 docs/planning/新增MCP服务工作流.md 第 3 步）。'
    if ($isPython) {
        $runLines = @(if ($Demo) {
            '# TODO(第 3 步)：接入真实上游时，把下面的演示服务换成拉起上游进程，例如：'
            '#   import subprocess'
            '#   raise SystemExit(subprocess.call([sys.executable, "-m", "<上游模块>", "stdio"]))'
            'run_demo_server(section)'
        } else {
            '# TODO(第 3 步)：在这里拉起真实上游（参考 mcp-gerrit/launcher.py）。'
            ('fail("{0}")' -f $notWired)
        })
        $runBody = (($runLines | ForEach-Object { '    ' + $_ }) -join "`n")
    }
    else {
        $runLines = @(if ($Demo) {
            '// TODO(第 3 步)：接入真实上游时，把下面的演示服务换成拉起上游，例如：'
            '//   await import("<上游入口>");'
            'runDemoServer(section);'
        } else {
            '// TODO(第 3 步)：在这里拉起真实上游（参考 mcp-jenkins/launcher.mjs）。'
            ('fail("{0}");' -f $notWired)
        })
        $runBody = (($runLines | ForEach-Object { '  ' + $_ }) -join "`n")
    }

    $replace = [ordered]@{
        '__ID__'             = $Id
        '__KEY__'            = $key
        '__DISPLAY__'        = $DisplayName
        '__DATE__'           = (Get-Date -Format 'yyyy-MM-dd')
        '__LAUNCHER__'       = $launcherName
    }
    $launcherTemplate = $(if ($isPython) { $script:McpScaffoldPythonLauncher } else { $script:McpScaffoldNodeLauncher })

    # 先替换较长的占位符，再替换 __ID__（避免 __ID__ 抢先吃掉其他键的片段）
    $launcher = $launcherTemplate.Replace('__DEMO_FUNCTION__', $(if ($Demo) { $demoFunction } else { '' }))
    $launcher = $launcher.Replace('__RUN_BODY__', $runBody)
    $launcher = Expand-McpScaffoldText -Text $launcher -Replace $replace

    if ($isPython) {
        if ($Demo) {
            $deps = "# 依赖与锁版本（第 2 步）。下面一行是演示服务的依赖，接入真实上游后替换为上游包的锁定版本。`nmcp==1.30.0`n"
        } else {
            $deps = "# 依赖与锁版本（第 2 步）：写入上游包及版本，例如：`n# some-mcp-server==1.2.3`n"
        }
    }
    else {
        $deps = ((@(
            '{'
            '  "name": "__ID__",'
            '  "version": "0.0.0",'
            '  "private": true,'
            '  "description": "__DISPLAY__ 启动器（本地 MCP 服务，由 scripts/bootstrap.ps1 安装依赖）",'
            '  "type": "module",'
            '  "dependencies": {}'
            '}'
        ) -join "`n") + "`n")
    }

    $generated = New-Object System.Collections.Generic.List[string]
    Write-McpScaffoldFile -Path (Join-Path $targetDir $launcherName) -Content $launcher -Overwrite $Force
    $generated.Add("$Id/$launcherName")
    Write-McpScaffoldFile -Path (Join-Path $targetDir $depsName) -Content (Expand-McpScaffoldText -Text $deps -Replace $replace) -Overwrite $Force
    $generated.Add("$Id/$depsName")

    $startCommand = $(if ($isPython) { "@('$Id/venv/Scripts/python.exe', '$Id/$launcherName')" } else { "@('node', '$Id/$launcherName')" })

    Write-Output ''
    Write-Output '==== 新增 MCP 服务：脚手架已生成 ===='
    Write-Output ('  服务目录：{0}' -f $targetDir)
    foreach ($g in $generated) { Write-Output ('  已生成：{0}' -f $g) }
    Write-Output ''
    Write-Output '还需手工完成 6 处（流程与完成判据见 docs/planning/新增MCP服务工作流.md）：'
    Write-Output ''
    Write-Output '  [1] 注册表 scripts/mcpctl.config.ps1（第 4 步）——在 $script:McpServices 末尾追加：'
    Write-Output '    @{'
    Write-Output ("        Code           = '{0}'" -f $code)
    Write-Output ("        Id             = '{0}'" -f $Id)
    Write-Output ("        DisplayName    = '{0}'" -f $DisplayName)
    Write-Output ("        StartCommand   = {0}" -f $startCommand)
    Write-Output ("        ConfigKey      = '{0}'" -f $key)
    Write-Output ("        PidFile        = '{0}/run.pid'" -f $Id)
    Write-Output ("        LogFile        = '{0}/logs/service.log'" -f $Id)
    Write-Output ("        Stack          = '{0}'" -f $Stack)
    Write-Output '    }'
    Write-Output ("  [2] 模板 mcp.config.sample.json（第 5 步）——services 中新增 '{0}' 段并补 _hints（必填项先写占位符，地址类参考值带 example.com）" -f $key)
    Write-Output ("  [3] Schema mcp.config.schema.json（第 5 步）——definitions 中新增 '{0}'，properties.services 中新增同名键" -f $key)
    Write-Output ("  [4] 配置向导字段目录 scripts/lib/config-wizard.ps1（第 6 步）——{0} 中新增 '{1} = @(...)'（字段集合须与模板一致）" -f '$script:McpSuiteFieldCatalog', $key)
    Write-Output ("  [5] 网关样例 gateway.routes.sample.json（第 7 步）——mcpServers 新增一条；scripts/lib/gateway-routes.ps1 的 {0} 中新增 '{1}' = '<服务名>'" -f '$script:McpGatewayNames', $Id)
    Write-Output ("  [6] 自检用例（第 8 步）——新增 scripts/tests/test-{0}.bat；scripts/tests/cases/services.json 的 services 中新增一条（id、configKey、gatewayName、expectedTools、readOnlyCall）" -f $key)
    Write-Output ''
    Write-Output '随后的文档与验证（第 9、10 步）：'
    Write-Output '  - docs/services/服务接入说明.md 新增小节；docs/services/配置字段说明.md 字段全表新增该服务的字段行'
    Write-Output '  - docs/01-文档台账.md、docs/operations/任务清单.md、docs/operations/更新记录.md 同步'
    Write-Output ("  - 运行 scripts\bootstrap.ps1 初始化依赖环境，再运行 scripts\tests\run-tests.bat --service {0}" -f $Id)
    Write-Output '  - 提交前确认 CI 的「新增服务一致性检查」通过；漏改上面任一处都会被指出'
    Write-Output ''
}

# ---------------------------------------------------------------------------
# 直接运行入口（被 dot-source 时不执行）
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-McpNewService -Id $Id -DisplayName $DisplayName -Stack $Stack -ConfigKey $ConfigKey -Demo ([bool]$Demo) -Force ([bool]$Force)
        exit 0
    }
    catch {
        [Console]::Error.WriteLine('新增服务脚手架失败：' + $_.Exception.Message)
        exit 1
    }
}
