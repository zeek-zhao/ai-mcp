#!/usr/bin/env node
// ai-mcp 自检核心（T-TEST-01）。Node 18+，只用内置模块。
//
// 用法：
//   node scripts/tests/lib/mcp-stdio-test.mjs [--service <服务Id>] [--structural] [--via gateway]
//        [--gateway-url <url>] [--gateway-agent <名称>] [--config <统一配置路径>] [--expect-tools <n>]
//        [--only <服务Id,服务Id…>] [--preflight] [--timeout-ms <毫秒>] [--help]
//        [--snapshot] [--diff]
//
// 工具快照（T-FLOW-02，仅直连模式，需要真实配置）：
//   --snapshot  把 tools/list 写入 scripts/tests/tools-snapshot/<服务Id>.json（工具名、说明哈希、必填字段、参数名）
//   --diff      与已入库的快照比较，输出「新增 / 删除 / 签名变化」三类清单；无变化退出码 0，有变化退出码 1
//
// 退出码（四态）：
//   0 = PASS     所选服务全部通过（SKIP 不计失败）
//   1 = FAIL     至少一项断言失败（结构不一致、工具数不符、只读调用失败、--diff 发现工具差异）
//   2 = BLOCKED  环境或前置不满足（找不到 node、依赖未安装、统一配置缺失或未就绪、启动器无法拉起、网关不可达、没有快照文件）
//   3 = USAGE    参数错误（发现即返回，不再执行）
// 多个服务同时运行时取最严重的结果：FAIL > BLOCKED > PASS。
//
// 安全：只打印工具名、条数、耗时与成败，不打印统一配置的任何取值；错误文本经 sanitize() 去掉地址与长随机串。
// 快照文件只含工具名、说明哈希与字段名，不含凭证与实例信息。

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TESTS_DIR = path.resolve(HERE, "..");
const DEFAULT_ROOT = path.resolve(TESTS_DIR, "..", "..");
const CASES_PATH = path.join(TESTS_DIR, "cases", "services.json");
const SAMPLE_FILE = "mcp.config.sample.json";
const SCHEMA_FILE = "mcp.config.schema.json";
const REGISTRY_FILE = path.join("scripts", "mcpctl.config.ps1");
const GATEWAY_ROUTES_FILE = path.join("scripts", "lib", "gateway-routes.ps1");
const GATEWAY_SAMPLE_FILE = "gateway.routes.sample.json";
const SNAPSHOT_DIR = path.join(TESTS_DIR, "tools-snapshot");
const DIFF_SUMMARY_KEYWORD = "工具快照差异";
const CONFIG_ENV_NAME = "MCP_SUITE_CONFIG";
const ROOT_ENV_NAME = "MCP_SUITE_ROOT";
const EXIT = { PASS: 0, FAIL: 1, BLOCKED: 2, USAGE: 3 };
const TEMPLATE_VALUE_PATTERN = /(example\.com|example\.net|yourcompany|zhangsan|your-name|your-company)/i;
const PROTOCOL_VERSION = "2025-06-18";
const IS_WIN = process.platform === "win32";

// ---------- 参数 ----------
function parseArgs(argv) {
  const out = { service: null, structural: false, via: null, gatewayUrl: null, gatewayAgent: "dsh", config: null, expectTools: null, only: null, preflight: false, snapshot: false, diff: false, help: false, timeoutMs: 60000 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => { if (i + 1 >= argv.length) { throw new Error(`选项 ${a} 缺少取值`); } return argv[++i]; };
    if (a === "--service") { out.service = next(); }
    else if (a === "--structural") { out.structural = true; }
    else if (a === "--via") { out.via = next(); }
    else if (a === "--gateway-url") { out.gatewayUrl = next(); }
    else if (a === "--gateway-agent") { out.gatewayAgent = next(); }
    else if (a === "--config") { out.config = next(); }
    else if (a === "--expect-tools") { out.expectTools = Number(next()); }
    else if (a === "--only") { out.only = String(next()).split(",").map((s) => s.trim()).filter(Boolean); }
    else if (a === "--preflight") { out.preflight = true; }
    else if (a === "--snapshot") { out.snapshot = true; }
    else if (a === "--diff") { out.diff = true; }
    else if (a === "--timeout-ms") { out.timeoutMs = Number(next()); }
    else if (a === "--help" || a === "-h") { out.help = true; }
    else { throw new Error(`未知参数：${a}`); }
  }
  if (out.via !== null && out.via !== "gateway") { throw new Error("--via 只支持 gateway"); }
  if (out.expectTools !== null && (!Number.isInteger(out.expectTools) || out.expectTools < 0)) { throw new Error("--expect-tools 须为非负整数"); }
  if (!Number.isInteger(out.timeoutMs) || out.timeoutMs <= 0) { throw new Error("--timeout-ms 须为正整数"); }
  if (out.snapshot && out.diff) { throw new Error("--snapshot 与 --diff 不能同时使用"); }
  if ((out.snapshot || out.diff) && (out.structural || out.via !== null || out.preflight)) {
    throw new Error("--snapshot / --diff 只支持直连模式，不能与 --structural、--via gateway、--preflight 同时使用");
  }
  return out;
}

function usage(message) {
  if (message) { console.log(`参数错误：${message}`); }
  console.log("用法：node scripts/tests/lib/mcp-stdio-test.mjs [--service <服务Id>] [--structural] [--via gateway] [--gateway-url <url>] [--gateway-agent <名称>] [--config <统一配置路径>] [--expect-tools <n>] [--only <服务Id,…>] [--preflight] [--snapshot] [--diff] [--timeout-ms <毫秒>] [--help]");
  console.log("退出码：0 通过；1 失败（含 --diff 发现工具差异）；2 环境或前置不满足；3 参数错误。");
  return EXIT.USAGE;
}

// ---------- 工具函数 ----------
function sanitize(text) {
  return String(text ?? "")
    .replace(/https?:\/\/\S+/gi, "<地址>")
    .replace(/[A-Za-z0-9_\-]{32,}/g, "<已隐藏>")
    .replace(/\s+/g, " ")
    .trim();
}
function firstLine(text) {
  const line = String(text ?? "").split(/\r?\n/).map((s) => s.trim()).find((s) => s.length > 0);
  return sanitize(line || "");
}
function isTemplate(value) { return TEMPLATE_VALUE_PATTERN.test(String(value)); }
function isPlaceholder(value) { return /^\s*<.*>\s*$/.test(String(value)); }
function isFilled(value) { const s = String(value ?? "").trim(); return s.length > 0 && !isPlaceholder(s) && !isTemplate(s); }
function hasSeparator(item) { return /[\\/]/.test(item) || path.isAbsolute(item); }
function validRoot(dir) { try { return typeof dir === "string" && dir.length > 0 && existsSync(path.join(dir, "scripts", "mcpctl.config.ps1")); } catch { return false; } }
function readJson(file) { return JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, "")); }

// ---------- 工具快照（T-FLOW-02） ----------
function sha256(text) { return createHash("sha256").update(String(text ?? ""), "utf8").digest("hex").slice(0, 16); }
// 每个工具只保留：名称、说明哈希、必填字段、参数名（不含说明原文、默认值、枚举，更不含凭证或实例信息）
function digestTool(tool) {
  const schema = tool?.inputSchema && typeof tool.inputSchema === "object" ? tool.inputSchema : {};
  const required = Array.isArray(schema.required) ? schema.required.map(String) : [];
  const properties = schema.properties && typeof schema.properties === "object" ? Object.keys(schema.properties) : [];
  return { name: String(tool?.name ?? ""), descriptionHash: sha256(tool?.description ?? ""), required: [...new Set(required)].sort(), properties: [...new Set(properties)].sort() };
}
function snapshotPath(caseDef) { return path.join(SNAPSHOT_DIR, `${caseDef.id}.json`); }
function readSnapshot(caseDef) {
  const file = snapshotPath(caseDef);
  const label = `scripts/tests/tools-snapshot/${caseDef.id}.json`;
  if (!existsSync(file)) { return { problem: `没有快照文件 ${label}（先运行 scripts\\tests\\run-tests.bat --snapshot）` }; }
  let doc;
  try { doc = readJson(file); } catch (e) { return { problem: `快照文件 ${label} 不是合法 JSON：${sanitize(e.message)}` }; }
  if (!doc || !Array.isArray(doc.tools) || doc.tools.some((t) => !t || typeof t.name !== "string" || typeof t.descriptionHash !== "string")) {
    return { problem: `快照文件 ${label} 格式不正确（需要 tools 数组，每项含 name 与 descriptionHash）` };
  }
  return { doc };
}
function writeSnapshot(caseDef, digests) {
  const tools = [...digests].sort((a, b) => a.name.localeCompare(b.name, "en"));
  const doc = {
    _comment: "工具快照（T-FLOW-02）：只含工具名、说明哈希与字段名，不含凭证与实例信息。由 scripts/tests/run-tests.bat --snapshot 生成，请勿手工编辑。",
    service: caseDef.id,
    capturedAt: new Date().toISOString().slice(0, 10),
    toolCount: tools.length,
    tools,
  };
  mkdirSync(SNAPSHOT_DIR, { recursive: true });
  writeFileSync(snapshotPath(caseDef), `${JSON.stringify(doc, null, 2)}\n`, "utf8");
  return doc;
}
// 比较「新增 / 删除 / 签名变化」；签名 = 必填字段 + 参数名 + 说明哈希
function diffSnapshot(doc, digests) {
  const before = new Map(doc.tools.map((t) => [t.name, t]));
  const after = new Map(digests.map((t) => [t.name, t]));
  const added = digests.filter((t) => !before.has(t.name)).map((t) => t.name);
  const removed = doc.tools.filter((t) => !after.has(t.name)).map((t) => t.name);
  const changed = [];
  for (const t of digests) {
    const old = before.get(t.name);
    if (!old) { continue; }
    const notes = [];
    const oldRequired = Array.isArray(old.required) ? old.required : [];
    const oldProps = Array.isArray(old.properties) ? old.properties : [];
    const reqAdded = t.required.filter((x) => !oldRequired.includes(x));
    const reqRemoved = oldRequired.filter((x) => !t.required.includes(x));
    if (reqAdded.length || reqRemoved.length) {
      const delta = [...reqAdded.map((x) => `新增 ${x}`), ...reqRemoved.map((x) => `删除 ${x}`)].join("、");
      notes.push(`必填字段 快照 [${oldRequired.join(", ")}] → 当前 [${t.required.join(", ")}]（${delta}）`);
    }
    const propAdded = t.properties.filter((x) => !oldProps.includes(x));
    const propRemoved = oldProps.filter((x) => !t.properties.includes(x));
    if (propAdded.length || propRemoved.length) {
      const delta = [...propAdded.map((x) => `新增 ${x}`), ...propRemoved.map((x) => `删除 ${x}`)].join("、");
      notes.push(`参数 快照 ${oldProps.length} 个 → 当前 ${t.properties.length} 个（${delta}）`);
    }
    if (old.descriptionHash !== t.descriptionHash) { notes.push("说明已变化"); }
    if (notes.length) { changed.push({ name: t.name, notes }); }
  }
  return { added, removed, changed };
}
function commandAvailable(name) {
  const probe = IS_WIN ? spawnSync("where", [name], { windowsHide: true }) : spawnSync("which", [name]);
  return probe.status === 0;
}
function findInterpreter(candidates) { for (const c of candidates) { if (commandAvailable(c)) { return c; } } return null; }
// 结构模式的回退解释器：venv 未安装（如 CI Runner）时用 PATH 上的 Python；须实测可运行（排除 Windows 商店占位程序，退出码 9009）
function probeInterpreter(command, prefixArgs) {
  const probe = spawnSync(command, [...prefixArgs, "--version"], { windowsHide: true, encoding: "utf8", timeout: 20000 });
  const output = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
  if (probe.status === 0 && /Python \d+/i.test(output)) { return { command, prefixArgs }; }
  return null;
}
function findPythonFallback() {
  for (const candidate of [["python", []], ["python3", []], [IS_WIN ? "py" : "python3", ["-3"]]]) {
    const found = probeInterpreter(candidate[0], candidate[1]);
    if (found) { return found; }
  }
  return null;
}
function killTree(child) {
  if (!child || child.exitCode !== null) { return; }
  if (IS_WIN) { spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" }); }
  else { try { child.kill("SIGKILL"); } catch { /* 已退出 */ } }
}

// 仓库根：与启动器相同的优先级（MCP_SUITE_ROOT 须为有效仓库根），否则按脚本位置推断
function resolveRoot() {
  const envRoot = String(process.env[ROOT_ENV_NAME] ?? "").trim();
  if (envRoot && validRoot(envRoot)) { return path.resolve(envRoot); }
  return DEFAULT_ROOT;
}
// 统一配置：MCP_SUITE_CONFIG > MCP_SUITE_ROOT\mcp.config.json > 仓库根\mcp.config.json
function resolveConfigPath(root) {
  const override = String(process.env[CONFIG_ENV_NAME] ?? "").trim();
  if (override) { return path.resolve(override); }
  return path.join(root, "mcp.config.json");
}

function readRegistry(root) {
  const text = readFileSync(path.join(root, REGISTRY_FILE), "utf8").replace(/^\uFEFF/, "");
  const entries = new Map();
  const re = /Code\s*=\s*'([^']+)'[\s\S]*?Id\s*=\s*'([^']+)'[\s\S]*?StartCommand\s*=\s*@\(([^)]*)\)[\s\S]*?ConfigKey\s*=\s*'([^']+)'[\s\S]*?Stack\s*=\s*'([^']+)'/g;
  for (const m of text.matchAll(re)) {
    const startCommand = [...m[3].matchAll(/'([^']*)'/g)].map((x) => x[1]);
    entries.set(m[2], { code: m[1], id: m[2], startCommand, configKey: m[4], stack: m[5] });
  }
  return entries;
}
function readGatewayNames(root) {
  const text = readFileSync(path.join(root, GATEWAY_ROUTES_FILE), "utf8").replace(/^\uFEFF/, "");
  const block = /McpGatewayNames\s*=\s*\[ordered\]@\{([\s\S]*?)\}/.exec(text);
  const names = new Map();
  if (block) { for (const m of block[1].matchAll(/'([^']+)'\s*=\s*'([^']+)'/g)) { names.set(m[1], m[2]); } }
  return names;
}
function readRequiredFields(schema) {
  const out = new Map();
  for (const [key, def] of Object.entries(schema?.definitions ?? {})) {
    if (Array.isArray(def.required)) { out.set(key, def.required.filter((k) => k !== "enabled")); }
  }
  return out;
}

// ---------- 结构校验（无需凭证与依赖，CI 必跑） ----------
// snapshotMode = 正在写入快照（--snapshot）：此时不校验快照是否存在、是否与期望数一致（否则无法生成第一份快照）
function staticChecks(ctx, snapshotMode = false) {
  const problems = [];
  if (ctx.registry.size === 0) { problems.push("注册表解析不到任何服务（scripts/mcpctl.config.ps1 的 Id / StartCommand / ConfigKey / Stack 写法可能已变）"); }
  const caseIds = ctx.cases.map((c) => c.id);
  const dup = caseIds.filter((id, i) => caseIds.indexOf(id) !== i);
  for (const id of dup) { problems.push(`用例 ${id} 重复`); }
  for (const id of ctx.registry.keys()) { if (!caseIds.includes(id)) { problems.push(`注册表服务 ${id} 没有对应用例：请在 scripts/tests/cases/services.json 增加（期望工具数与一条只读调用）`); } }
  for (const c of ctx.cases) {
    const reg = ctx.registry.get(c.id);
    if (!reg) { problems.push(`用例 ${c.id} 在注册表中不存在`); continue; }
    if (c.configKey !== reg.configKey) { problems.push(`用例 ${c.id} 的 configKey（${c.configKey}）与注册表（${reg.configKey}）不一致`); }
    const expectedName = ctx.gatewayNames.get(c.id);
    if (!c.gatewayName || c.gatewayName !== expectedName) { problems.push(`用例 ${c.id} 的 gatewayName（${c.gatewayName ?? "空"}）与 scripts/lib/gateway-routes.ps1 的 McpGatewayNames（${expectedName ?? "未登记"}）不一致`); }
    if (!(c.gatewayName in (ctx.gatewaySample?.mcpServers ?? {}))) { problems.push(`网关样例 ${GATEWAY_SAMPLE_FILE} 中没有服务 ${c.gatewayName ?? "（空）"}`); }
    if (!Number.isInteger(c.expectedTools) || c.expectedTools <= 0) { problems.push(`用例 ${c.id} 的 expectedTools 须为正整数`); }
    if (!c.readOnlyCall || typeof c.readOnlyCall.tool !== "string" || !c.readOnlyCall.tool) { problems.push(`用例 ${c.id} 缺少 readOnlyCall.tool`); }
    if (!Number.isInteger(reg.startCommand.length) || reg.startCommand.length < 2 || reg.startCommand.some((s) => !s)) { problems.push(`注册表服务 ${c.id} 的 StartCommand 未回填或少于两项`); continue; }
    const launcher = hasSeparator(reg.startCommand[1]) ? path.resolve(ctx.root, reg.startCommand[1]) : null;
    if (!launcher || !existsSync(launcher)) { problems.push(`注册表服务 ${c.id} 的启动器不存在：${reg.startCommand[1]}`); }
    if (!(reg.configKey in (ctx.sample?.services ?? {}))) { problems.push(`模板 ${SAMPLE_FILE} 中没有配置段 services.${reg.configKey}`); }
  }
  // 工具快照（T-FLOW-02）：每个用例必须有快照，且工具数与期望一致（期望数改了而快照没更新 = 升级流程第 4、5 步没走完）
  if (!snapshotMode) {
    for (const f of (existsSync(SNAPSHOT_DIR) ? readdirSync(SNAPSHOT_DIR) : [])) {
      if (f.endsWith(".json") && !caseIds.includes(f.slice(0, -5))) { problems.push(`快照 scripts/tests/tools-snapshot/${f} 没有对应用例`); }
    }
    for (const c of ctx.cases) {
      const snap = readSnapshot(c);
      if (snap.problem) { problems.push(`用例 ${c.id} ${snap.problem}`); continue; }
      const names = snap.doc.tools.map((t) => t.name);
      const dupNames = names.filter((n, i) => names.indexOf(n) !== i);
      if (dupNames.length) { problems.push(`用例 ${c.id} 的快照有重复工具名：${[...new Set(dupNames)].join("、")}`); }
      if (snap.doc.toolCount !== names.length) { problems.push(`用例 ${c.id} 的快照 toolCount（${snap.doc.toolCount}）与 tools 条数（${names.length}）不一致`); }
      if (names.length !== c.expectedTools) {
        problems.push(`用例 ${c.id} 的快照工具数（${names.length}）与 expectedTools（${c.expectedTools}）不一致：升级后先运行 run-tests.bat --diff 评估差异，再用 run-tests.bat --snapshot 更新快照`);
      }
    }
  }
  return problems;
}

// ---------- 就绪判断（与 mcpctl 的就绪规则一致，只输出状态，不输出取值） ----------
function configState(ctx, caseDef, cfg) {
  const section = cfg?.services?.[caseDef.configKey];
  if (!section) { return { state: "not-ready", reason: `统一配置缺少 services.${caseDef.configKey} 配置段` }; }
  if (section.enabled === false) { return { state: "disabled", reason: "服务已在统一配置中禁用" }; }
  if (section.enabled !== true) { return { state: "not-ready", reason: `services.${caseDef.configKey}.enabled 不是布尔值` }; }
  const required = [...(ctx.required.get(caseDef.configKey) ?? [])];
  if (caseDef.configKey === "atlassian" && String(section.deployment).toLowerCase() === "cloud") { required.push("email"); }
  for (const name of required) {
    const value = section[name];
    if (!isFilled(value)) {
      const kind = String(value ?? "").trim() === "" ? "未填写" : isPlaceholder(value) ? "仍是占位符" : "仍是模板参考值";
      return { state: "not-ready", reason: `services.${caseDef.configKey}.${name} ${kind}`, kind };
    }
  }
  return { state: "ready", reason: "" };
}

// ---------- 启动命令解析 ----------
function resolveCommand(ctx, reg, structural) {
  const items = reg.startCommand;
  const first = items[0];
  if (hasSeparator(first)) {
    const abs = path.resolve(ctx.root, first);
    if (existsSync(abs)) { return { command: abs, problem: null }; }
    if (structural && /python\.exe$/i.test(first)) {
      const interpreter = findPythonFallback();
      if (interpreter) { return { ...interpreter, problem: null, fallback: true }; }
    }
    return { command: null, problem: `依赖未安装：缺少 ${first}（先运行 scripts/bootstrap.ps1；结构模式下也可安装常规发行版 Python 3 到 PATH）` };
  }
  if (commandAvailable(first)) { return { command: first, problem: null }; }
  return { command: null, problem: `PATH 中找不到 ${first}` };
}

// ---------- stdio JSON-RPC 客户端 ----------
class StdioClient {
  constructor(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = "";
    this.stderr = "";
    this.exited = null;
    child.stderr.on("data", (d) => { this.stderr += d.toString("utf8"); });
    child.on("exit", (code, signal) => { this.exited = { code, signal }; for (const p of this.pending.values()) { p.reject(new Error(`启动器已退出（退出码 ${code}）：${firstLine(this.stderr) || "无错误输出"}`)); } this.pending.clear(); });
    child.stdout.on("data", (d) => this.onData(d));
    child.stdin.on("error", () => { /* 进程已退出时的写入错误，忽略 */ });
  }
  onData(d) {
    this.buffer += d.toString("utf8");
    let idx;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) { continue; }
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) { p.reject(new Error(`JSON-RPC 错误 ${msg.error.code}：${sanitize(msg.error.message)}`)); } else { p.resolve(msg.result); }
      }
    }
  }
  send(payload) { this.child.stdin.write(JSON.stringify(payload) + "\n"); }
  request(method, params, timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} 超时（${timeoutMs} 毫秒）`)); }, timeoutMs);
      this.pending.set(id, { resolve: (v) => { clearTimeout(timer); resolve(v); }, reject: (e) => { clearTimeout(timer); reject(e); } });
      try { this.send({ jsonrpc: "2.0", id, method, params }); } catch (e) { this.pending.delete(id); clearTimeout(timer); reject(new Error(`无法写入启动器标准输入：${sanitize(e.message)}`)); }
    });
  }
  notify(method, params) { try { this.send({ jsonrpc: "2.0", method, params }); } catch { /* 忽略 */ } }
}

function startLauncher(ctx, reg, configPath, structural) {
  const resolved = resolveCommand(ctx, reg, structural);
  if (resolved.problem) { return { problem: resolved.problem }; }
  const args = [...(resolved.prefixArgs ?? []), ...reg.startCommand.slice(1).map((it) => (hasSeparator(it) ? path.resolve(ctx.root, it) : it))];
  const child = spawn(resolved.command, args, { cwd: ctx.root, env: { ...process.env, [CONFIG_ENV_NAME]: configPath, PYTHONUTF8: "1" }, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  const client = new StdioClient(child);
  return { client, child, fallback: Boolean(resolved.fallback), interpreter: resolved.command };
}

async function listToolDefs(client, timeoutMs) {
  const tools = [];
  let cursor;
  for (let page = 0; page < 20; page++) {
    const result = await client.request("tools/list", cursor ? { cursor } : {}, timeoutMs);
    for (const t of result?.tools ?? []) { tools.push(t); }
    cursor = result?.nextCursor;
    if (!cursor) { break; }
  }
  return tools;
}

// ---------- 直连模式 ----------
async function runDirect(ctx, caseDef, opts) {
  const reg = ctx.registry.get(caseDef.id);
  const expected = opts.expectTools ?? caseDef.expectedTools;
  if (opts.structural) {
    // 结构模式：用模板当配置，启动器必须拒绝（模板参考值 / 占位符），不读取 stdin
    const configPath = opts.config ? path.resolve(opts.config) : path.join(ctx.root, SAMPLE_FILE);
    const started = startLauncher(ctx, reg, configPath, true);
    if (started.problem) { return { status: "BLOCKED", reason: started.problem }; }
    const note = started.fallback ? `（${path.basename(String(started.interpreter))} 来自 PATH，venv 未安装）` : "";
    const outcome = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve({ kind: "running" }), 15000);
      started.child.on("exit", (code) => { clearTimeout(timer); resolve({ kind: "exit", code }); });
    });
    if (outcome.kind === "running") {
      killTree(started.child);
      return { status: "FAIL", reason: "启动器没有拒绝模板配置（15 秒内仍在运行）；模板参考值与占位符的判定可能已失效" };
    }
    const line = firstLine(started.client.stderr);
    if (outcome.code !== 0 && /占位符|模板参考值/.test(started.client.stderr)) {
      return { status: "SKIP", reason: `启动器按预期拒绝模板配置${note}：${line}` };
    }
    return { status: "BLOCKED", reason: `启动器以模板配置启动时异常退出（退出码 ${outcome.code}）：${line || "无错误输出"}` };
  }
  const configPath = opts.config ? path.resolve(opts.config) : resolveConfigPath(ctx.root);
  if (!existsSync(configPath)) { return { status: "BLOCKED", reason: "统一配置不存在（先运行 scripts/mcpctl.ps1 菜单 4 配置向导）" }; }
  let cfg;
  try { cfg = readJson(configPath); } catch (e) { return { status: "BLOCKED", reason: `统一配置不是合法 JSON：${sanitize(e.message)}` }; }
  const state = configState(ctx, caseDef, cfg);
  if (state.state === "disabled") { return { status: "SKIP", reason: state.reason }; }
  if (state.state !== "ready") { return { status: "BLOCKED", reason: `统一配置未就绪：${state.reason}` }; }
  const started = startLauncher(ctx, reg, configPath, false);
  if (started.problem) { return { status: "BLOCKED", reason: started.problem }; }
  const { client } = started;
  const details = [];
  try {
    const t0 = Date.now();
    const init = await client.request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "ai-mcp-selftest", version: "1.0.0" } }, opts.timeoutMs);
    client.notify("notifications/initialized", {});
    details.push(`握手成功（${((Date.now() - t0) / 1000).toFixed(1)} 秒，serverInfo=${sanitize(init?.serverInfo?.name ?? "")}）`);
    const toolDefs = await listToolDefs(client, opts.timeoutMs);
    const names = toolDefs.map((t) => t.name);
    if (opts.snapshot) {
      // 快照模式：总是写入当前工具集；与期望数不符时提示更新用例
      const doc = writeSnapshot(caseDef, toolDefs.map(digestTool));
      details.push(`已写入快照 scripts/tests/tools-snapshot/${caseDef.id}.json（${doc.toolCount} 个工具）`);
      if (names.length !== expected) { return { status: "FAIL", reason: `工具数 ${names.length}，期望 ${expected}（快照已写入，请同步更新 scripts/tests/cases/services.json 的 expectedTools）`, details }; }
      return { status: "PASS", reason: "", details };
    }
    if (names.length !== expected) { return { status: "FAIL", reason: `工具数 ${names.length}，期望 ${expected}`, details }; }
    details.push(`工具数 ${names.length}（期望 ${expected}）`);
    if (opts.diff) {
      // 对比模式：与入库快照比较，输出「新增 / 删除 / 签名变化」；有差异即 FAIL（退出码 1）
      const snap = readSnapshot(caseDef);
      if (snap.problem) { return { status: "BLOCKED", reason: snap.problem, details }; }
      const d = diffSnapshot(snap.doc, toolDefs.map(digestTool));
      details.push(`${DIFF_SUMMARY_KEYWORD}（${caseDef.id}）：新增 ${d.added.length} / 删除 ${d.removed.length} / 签名变化 ${d.changed.length}`);
      if (d.added.length) { details.push(`  新增：${d.added.join("、")}`); }
      if (d.removed.length) { details.push(`  删除：${d.removed.join("、")}`); }
      for (const ch of d.changed) { details.push(`  签名变化：${ch.name}（${ch.notes.join("；")}）`); }
      if (d.added.length || d.removed.length || d.changed.length) { return { status: "FAIL", reason: "工具集与快照不一致（见上方差异清单）", details }; }
      details.push("与快照一致");
      return { status: "PASS", reason: "", details };
    }
    const call = caseDef.readOnlyCall;
    if (!names.includes(call.tool)) { return { status: "FAIL", reason: `用例的只读调用工具不存在：${call.tool}`, details }; }
    const t1 = Date.now();
    const result = await client.request("tools/call", { name: call.tool, arguments: call.arguments ?? {} }, opts.timeoutMs);
    const seconds = ((Date.now() - t1) / 1000).toFixed(1);
    if (result?.isError) { return { status: "FAIL", reason: `只读调用 ${call.tool} 返回错误（${seconds} 秒）：${firstLine((result.content ?? []).map((c) => c.text ?? "").join("\n"))}`, details }; }
    details.push(`只读调用 ${call.tool} 成功（${seconds} 秒）`);
    return { status: "PASS", reason: "", details };
  } catch (e) {
    return { status: "BLOCKED", reason: sanitize(e.message), details };
  } finally {
    try { started.child.stdin.end(); } catch { /* 忽略 */ }
    const exited = await new Promise((resolve) => { if (started.child.exitCode !== null) { resolve(true); return; } const timer = setTimeout(() => resolve(false), 5000); started.child.on("exit", () => { clearTimeout(timer); resolve(true); }); });
    if (!exited) { killTree(started.child); }
  }
}

// ---------- 网关模式（Magpie hub，streamable-http） ----------
class HubClient {
  constructor(url) { this.url = url; this.sessionId = null; this.nextId = 1; }
  async post(payload, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const headers = { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "MCP-Protocol-Version": PROTOCOL_VERSION };
    if (this.sessionId) { headers["mcp-session-id"] = this.sessionId; }
    let response;
    try { response = await fetch(this.url, { method: "POST", headers, body: JSON.stringify(payload), signal: controller.signal }); }
    catch (e) { throw new Error(`网关不可达（${sanitize(this.url)}）：${sanitize(e.message)}`); }
    finally { clearTimeout(timer); }
    const sid = response.headers.get("mcp-session-id");
    if (sid) { this.sessionId = sid; }
    const text = await response.text();
    if (!text.trim()) { return { status: response.status, message: null }; }
    let message = null;
    const body = text.trim();
    if (body.startsWith("{")) { message = JSON.parse(body); }
    else {
      for (const line of body.split(/\r?\n/)) {
        const s = line.trim();
        if (s.startsWith("data:")) { try { const obj = JSON.parse(s.slice(5).trim()); if (obj.result !== undefined || obj.error !== undefined) { message = obj; } } catch { /* 忽略 */ } }
      }
    }
    return { status: response.status, message };
  }
  async request(method, params, timeoutMs) {
    const id = this.nextId++;
    const { status, message } = await this.post({ jsonrpc: "2.0", id, method, params }, timeoutMs);
    if (!message) { throw new Error(`网关返回 HTTP ${status}，没有响应体`); }
    if (message.error) { throw new Error(`网关 JSON-RPC 错误 ${message.error.code}：${sanitize(message.error.message)}`); }
    return message.result;
  }
  async notify(method, params) { await this.post({ jsonrpc: "2.0", method, params }, 30000); }
}

async function runGateway(ctx, caseDef, opts, url) {
  const configPath = opts.config ? path.resolve(opts.config) : resolveConfigPath(ctx.root);
  if (!existsSync(configPath)) { return { status: "BLOCKED", reason: "统一配置不存在（网关拉起的启动器同样需要它）" }; }
  let cfg;
  try { cfg = readJson(configPath); } catch (e) { return { status: "BLOCKED", reason: `统一配置不是合法 JSON：${sanitize(e.message)}` }; }
  const state = configState(ctx, caseDef, cfg);
  if (state.state === "disabled") { return { status: "SKIP", reason: state.reason }; }
  if (state.state !== "ready") { return { status: "BLOCKED", reason: `统一配置未就绪：${state.reason}` }; }
  const expected = opts.expectTools ?? caseDef.expectedTools;
  const name = caseDef.gatewayName;
  const details = [];
  try {
    const hub = new HubClient(url);
    await hub.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "ai-mcp-selftest", version: "1.0.0" } }, opts.timeoutMs);
    await hub.notify("notifications/initialized", {});
    const found = await hub.request("tools/call", { name: "find_tools", arguments: { query: "", server: name } }, opts.timeoutMs);
    const text = (found?.content ?? []).map((c) => c.text ?? "").join("\n");
    const prefix = `${name}__`;
    const tools = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.startsWith(`- ${prefix}`)).map((l) => l.slice(2).split(":")[0].trim());
    if (tools.length !== expected) { return { status: "FAIL", reason: `网关侧工具数 ${tools.length}，期望 ${expected}`, details }; }
    details.push(`网关侧工具数 ${tools.length}（期望 ${expected}，工具名带前缀 ${prefix}）`);
    const call = caseDef.readOnlyCall;
    const fullName = `${prefix}${call.tool}`;
    if (!tools.includes(fullName)) { return { status: "FAIL", reason: `用例的只读调用在网关侧不存在：${fullName}`, details }; }
    const t1 = Date.now();
    const result = await hub.request("tools/call", { name: "call_tool", arguments: { name: fullName, arguments: call.arguments ?? {} } }, opts.timeoutMs);
    const seconds = ((Date.now() - t1) / 1000).toFixed(1);
    if (result?.isError) { return { status: "FAIL", reason: `网关只读调用 ${fullName} 返回错误（${seconds} 秒）：${firstLine((result.content ?? []).map((c) => c.text ?? "").join("\n"))}`, details }; }
    details.push(`网关只读调用 ${fullName} 成功（${seconds} 秒）`);
    return { status: "PASS", reason: "", details };
  } catch (e) {
    return { status: "BLOCKED", reason: sanitize(e.message), details };
  }
}

// ---------- 预检 ----------
async function preflight(ctx, selected, opts) {
  const rows = [];
  let blocked = 0;
  const configPath = opts.config ? path.resolve(opts.config) : resolveConfigPath(ctx.root);
  let cfg = null;
  let configNote = "就绪";
  if (!existsSync(configPath)) { configNote = "不存在"; }
  else { try { cfg = readJson(configPath); } catch { configNote = "不是合法 JSON"; } }
  for (const caseDef of selected) {
    const reg = ctx.registry.get(caseDef.id);
    const resolved = reg ? resolveCommand(ctx, reg, false) : { problem: "注册表中不存在" };
    const state = cfg && reg ? configState(ctx, caseDef, cfg) : { state: "unknown", reason: configNote };
    const dep = resolved.problem ? "未就绪" : "已就绪";
    const conf = !cfg ? configNote : state.state === "ready" ? "就绪" : state.state === "disabled" ? "已禁用" : "未就绪";
    const runnable = resolved.problem === null || !resolved.problem ? (cfg ? state.state !== "not-ready" && state.state !== "unknown" : false) : false;
    if (!runnable) { blocked++; }
    rows.push([caseDef.id, dep, conf, runnable ? "可执行" : "受阻"]);
  }
  console.log("预检（不显示任何配置取值）：");
  console.log(`  node：${process.version}；仓库根：${sanitize(ctx.root)}`);
  for (const r of rows) { console.log(`  ${r[0].padEnd(16)} 依赖=${r[1]}  配置=${r[2]}  ${r[3]}`); }
  if (opts.via === "gateway") {
    const url = gatewayUrl(opts);
    try {
      const hub = new HubClient(url);
      await hub.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "ai-mcp-selftest", version: "1.0.0" } }, opts.timeoutMs);
      console.log("  网关：可达");
    } catch (e) { blocked++; console.log(`  网关：不可达（${sanitize(e.message)}）`); }
  }
  console.log(blocked === 0 ? "预检结果：所选服务均可执行" : `预检结果：${blocked} 项受阻（退出码 2）`);
  return blocked === 0 ? EXIT.PASS : EXIT.BLOCKED;
}
function gatewayUrl(opts) {
  if (opts.gatewayUrl) { return opts.gatewayUrl; }
  return `http://127.0.0.1:3425/mcp/magpie/hub/${opts.gatewayAgent}`;
}

// ---------- 主流程 ----------
async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (e) { return usage(e.message); }
  if (opts.help) { console.log(readFileComment()); return EXIT.PASS; }
  const root = resolveRoot();
  const ctx = { root, cases: [], registry: new Map(), gatewayNames: new Map(), gatewaySample: null, sample: null, required: new Map() };
  try {
    const raw = readJson(CASES_PATH);
    ctx.cases = Array.isArray(raw) ? raw : raw.services;
    ctx.registry = readRegistry(root);
    ctx.gatewayNames = readGatewayNames(root);
    ctx.gatewaySample = readJson(path.join(root, GATEWAY_SAMPLE_FILE));
    ctx.sample = readJson(path.join(root, SAMPLE_FILE));
    ctx.required = readRequiredFields(readJson(path.join(root, SCHEMA_FILE)));
  } catch (e) {
    console.log(`结构校验失败：无法读取用例、注册表、模板或网关样例（${sanitize(e.message)}）`);
    return EXIT.FAIL;
  }
  if (!Array.isArray(ctx.cases) || ctx.cases.length === 0) { console.log("结构校验失败：scripts/tests/cases/services.json 没有 services 数组"); return EXIT.FAIL; }
  const problems = staticChecks(ctx, opts.snapshot);
  for (const p of problems) { console.log(`结构校验失败：${p}`); }
  if (problems.length > 0) { return EXIT.FAIL; }
  console.log(`结构校验通过：用例 ${ctx.cases.length} 条与注册表、模板、网关样例、启动器文件一致`);

  // --service / --only 可写服务 Id（mcp-gerrit）、配置段名（gerrit）或 mcp-<配置段名>，三者等价
  const selectorOf = (c) => [c.id, c.configKey, `mcp-${c.configKey}`];
  const selectedBy = (x) => ctx.cases.filter((c) => selectorOf(c).includes(x));
  let selected = opts.service ? selectedBy(opts.service) : ctx.cases.slice();
  if (opts.service && selected.length === 0) { return usage(`--service ${opts.service} 没有对应用例`); }
  if (opts.only) {
    const unknown = opts.only.filter((x) => selectedBy(x).length === 0);
    if (unknown.length > 0) { return usage(`--only 中的 ${unknown.join("、")} 没有对应用例`); }
    const wanted = new Set(opts.only.flatMap((x) => selectedBy(x).map((c) => c.id)));
    selected = selected.filter((c) => wanted.has(c.id));
  }
  if (opts.service && opts.only && selected.length === 0) { console.log(`[${opts.service}] 未被 --only 选中，跳过`); return EXIT.PASS; }
  if (opts.preflight) { return preflight(ctx, selected, opts); }

  const mode = opts.snapshot ? "快照模式（写入 scripts/tests/tools-snapshot，需要真实配置）"
    : opts.diff ? "对比模式（与 scripts/tests/tools-snapshot 比较，需要真实配置；有差异退出码 1）"
    : opts.structural ? "结构模式（模板配置）" : opts.via === "gateway" ? `网关模式（${sanitize(gatewayUrl(opts))}）` : "直连模式";
  console.log(`模式：${mode}`);
  const tally = { PASS: 0, FAIL: 0, SKIP: 0, BLOCKED: 0 };
  for (const caseDef of selected) {
    const started = Date.now();
    const result = opts.via === "gateway" ? await runGateway(ctx, caseDef, opts, gatewayUrl(opts)) : await runDirect(ctx, caseDef, opts);
    tally[result.status] += 1;
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    for (const d of result.details ?? []) { console.log(`  [${caseDef.id}] ${d}`); }
    const label = { PASS: "通过", FAIL: "失败", SKIP: "跳过", BLOCKED: "受阻" }[result.status];
    console.log(`[${caseDef.id}] 结果：${result.status}（${label}${result.reason ? "：" + result.reason : ""}；${seconds} 秒）`);
  }
  const code = tally.FAIL > 0 ? EXIT.FAIL : tally.BLOCKED > 0 ? EXIT.BLOCKED : EXIT.PASS;
  console.log(`汇总：PASS=${tally.PASS} FAIL=${tally.FAIL} SKIP=${tally.SKIP} BLOCKED=${tally.BLOCKED} → 退出码 ${code}`);
  return code;
}
function readFileComment() {
  const head = readFileSync(fileURLToPath(import.meta.url), "utf8").split(/\r?\n/).filter((l) => l.startsWith("// ") && !l.startsWith("// ai-mcp 自检核心")).map((l) => l.replace(/^\/\/ ?/, "")).join("\n");
  return head;
}

main().then((code) => { process.exitCode = code; }, (e) => { console.log(`自检脚本异常：${sanitize(e?.stack ?? e)}`); process.exitCode = EXIT.FAIL; });
