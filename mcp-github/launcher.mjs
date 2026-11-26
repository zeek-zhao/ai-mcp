// GitHub 官方 MCP server（stdio）本地启动器（模型一：由 Host 按需拉起，本进程生命周期完全由 Host 管理）。
//
// 配置来源：仓库根统一配置 mcp.config.json 的 services.github 配置段。
//   路径优先取环境变量 MCP_SUITE_CONFIG（绝对路径）；其次取环境变量 MCP_SUITE_ROOT（仓库根目录）下的
//   mcp.config.json；两者都未设置时回退到 <本服务目录>/../mcp.config.json。
//   MCP_SUITE_ROOT 已设置但无效时报错退出、不回退（判定与文案与 scripts/lib/registry.ps1 一致）。
// 字段映射：
//   pat     -> GITHUB_PERSONAL_ACCESS_TOKEN（官方服务器读取的变量名）
//   baseUrl -> GITHUB_HOST（官方服务器的 API 主机；填 https://github.com 时自动改写为 https://api.github.com，
//               GitHub Enterprise 填 API 地址后原样传入）
//   scope   仅作记录：官方服务器没有对应的限定参数，实际可见范围由令牌权限决定。
//
// 约束：stdout 只留给 MCP 协议，诊断信息一律写 stderr；任何输出不得包含令牌明文；
// 空值、占位符（<...> 形态）、模板参考值（带 example.com / zhangsan / yourcompany 等指纹）都视为未填写，
// 拒绝启动（与 mcpctl 配置向导的就绪判定一致）。
import { readFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const exe = path.join(here, "bin", "github-mcp-server.exe");
const TAG = "[github-launcher]";
const KEY = "github";
// 字段的中文名，与 scripts/lib/config-wizard.ps1 的字段目录保持一致
const LABELS = { enabled: "是否启用 GitHub", baseUrl: "GitHub 地址（GitHub Enterprise 填 API 地址）", pat: "个人访问令牌（PAT）" };

function fail(message) {
  console.error(`${TAG} ${message}`);
  process.exit(1);
}

const isPlaceholder = (v) => /^\s*<.*>\s*$/.test(v);
const text = (v) => (v === undefined || v === null ? "" : String(v)).trim();
// 模板参考值指纹：关键词必须与 scripts/lib/suite-config.ps1 的 $script:McpSuiteTemplateValuePattern 一致（CI 校验）
const TEMPLATE_VALUE_PATTERN = /(example\.com|example\.net|yourcompany|zhangsan|your-name|your-company)/i;

// 值未填写时返回中文说明（空值 / 占位符 / 模板参考值分开提示，与 mcpctl 的就绪判定文案一致）；已填写返回 null。
// 只给出命中的指纹关键词（如 example.com），不回显字段值。
function unfilledText(value) {
  if (!value) return "未填写，请填写";
  if (isPlaceholder(value)) return "仍是占位符，需填写真实值";
  const hit = TEMPLATE_VALUE_PATTERN.exec(value);
  if (hit) return `仍是模板参考值（特征：${hit[1].toLowerCase()}），需替换为真实值`;
  return null;
}

function requireFilled(name, value) {
  const issue = unfilledText(value);
  if (issue) fail(`统一配置 services.${KEY}.${name}（${LABELS[name]}）${issue}。`);
}

const ROOT_CLEAR_COMMAND = 'setx MCP_SUITE_ROOT ""';

// 定位统一配置：MCP_SUITE_CONFIG > MCP_SUITE_ROOT/mcp.config.json > <本服务目录>/../mcp.config.json
function resolveConfigPath() {
  const override = text(process.env.MCP_SUITE_CONFIG);
  if (override) return path.resolve(override);
  const rootEnv = text(process.env.MCP_SUITE_ROOT);
  if (rootEnv) {
    // 与 scripts/lib/registry.ps1 的判定和报错文案保持逐字一致；无效时不回退
    if (!path.isAbsolute(rootEnv)) {
      fail(`环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：${rootEnv}。请改为正确的仓库根目录，或清除该变量后重试：${ROOT_CLEAR_COMMAND}`);
    }
    if (!existsSync(path.join(rootEnv, "scripts", "mcpctl.config.ps1"))) {
      fail(`环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：${rootEnv}。请改为正确的仓库根目录，或清除该变量后重试：${ROOT_CLEAR_COMMAND}`);
    }
    return path.join(rootEnv, "mcp.config.json");
  }
  return path.join(here, "..", "mcp.config.json");
}

// 读取统一配置并返回 services.github 配置段；任何问题都以中文说明退出
function loadSection() {
  const configPath = resolveConfigPath();
  if (!existsSync(configPath)) {
    fail(`统一配置文件不存在：${configPath}\n下一步：运行 mcpctl 配置向导（scripts/mcpctl.ps1 菜单 4）从模板生成 mcp.config.json 并填写。`);
  }
  let doc;
  try {
    doc = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (err) {
    // 不回显解析器的原始信息（可能夹带配置内容），只给出出错位置
    const raw = String((err && err.message) || "");
    const lc = /line (\d+) column (\d+)/.exec(raw);
    const pos = /position (\d+)/.exec(raw);
    const where = lc ? `（第 ${lc[1]} 行，第 ${lc[2]} 列附近）` : pos ? `（第 ${pos[1]} 个字符附近）` : "";
    fail(`统一配置不是合法 JSON：${configPath}${where}。请检查引号、逗号与括号是否成对。`);
  }
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    fail(`统一配置的顶层必须是 JSON 对象：${configPath}`);
  }
  if (doc.configVersion !== 1) {
    fail(`统一配置的 configVersion 不受支持：${configPath}（当前仅支持 1）`);
  }
  const services = doc.services;
  if (!services || typeof services !== "object" || Array.isArray(services)) {
    fail(`统一配置缺少 services 配置段，或该段不是对象：${configPath}（请对照 mcp.config.sample.json 补全）`);
  }
  const section = services[KEY];
  if (!section || typeof section !== "object" || Array.isArray(section)) {
    fail(`统一配置缺少 services.${KEY} 配置段：${configPath}（请对照 mcp.config.sample.json 补全）`);
  }
  return { section, configPath };
}

const { section } = loadSection();
if (section.enabled !== true) {
  fail(`GitHub 已在统一配置中禁用（services.${KEY}.enabled 不是 true），不启动。`);
}
const baseUrl = text(section.baseUrl).replace(/\/+$/, "");
const pat = text(section.pat);
requireFilled("baseUrl", baseUrl);
if (!/^https?:\/\//i.test(baseUrl)) {
  fail(`统一配置 services.${KEY}.baseUrl（${LABELS.baseUrl}）格式不正确：需以 http:// 或 https:// 开头。`);
}
requireFilled("pat", pat);
if (!existsSync(exe)) {
  fail(`二进制缺失：${exe}\n下一步：联网运行 mcp-github/setup-github-mcp.ps1 下载锁定版本的官方二进制后重试。`);
}

// 官方服务器用 GITHUB_HOST 表示 API 主机；不设置时默认 api.github.com。
// 模板参考值是 https://github.com，这里改写为 API 地址，避免把站点地址当成 API 主机。
let apiHost = baseUrl;
try {
  const u = new URL(baseUrl);
  if ((u.hostname.toLowerCase() === "github.com" || u.hostname.toLowerCase() === "www.github.com") && (u.pathname === "/" || u.pathname === "")) {
    apiHost = "https://api.github.com";
  }
} catch {
  fail(`统一配置 services.${KEY}.baseUrl（${LABELS.baseUrl}）无法解析为合法地址。`);
}

const env = { ...process.env, GITHUB_PERSONAL_ACCESS_TOKEN: pat, GITHUB_HOST: apiHost };

// v2.x 必须显式给出子命令；未传参时默认 stdio 服务器。
const args = process.argv.slice(2);
if (args.length === 0) args.push("stdio");

const child = spawn(exe, args, { env, stdio: "inherit" });
child.on("error", (err) => {
  console.error(`${TAG} 启动失败：${err.message}`);
  process.exit(1);
});
child.on("exit", (code) => process.exit(code ?? 0));
