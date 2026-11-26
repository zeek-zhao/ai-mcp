/**
 * mcp-jenkins 本地启动器（模型一：由 Host 按需 stdio 拉起，本进程生命周期完全由 Host 管理）。
 *
 * 配置来源：仓库根统一配置 mcp.config.json 的 services.jenkins 配置段。
 *   路径优先取环境变量 MCP_SUITE_CONFIG（绝对路径），未设置时回退到 <本服务目录>/../mcp.config.json。
 * 字段映射：
 *   baseUrl  -> JENKINS_URL
 *   username -> JENKINS_USERNAME
 *   apiToken -> JENKINS_API_TOKEN
 *   readOnly -> 仅提示：上游 jenkins-mcp-server 没有内建只读模式，写操作不会被拦截
 *
 * 上游服务入口通过动态 import 加载，以绕过其 validateConfig 的环境变量强校验。
 * 注意：上游 import 必须是动态的。ES module 的静态 import 会被提升并在任何
 * 顶层语句之前求值，若静态 import，环境变量会在配置注入前被读取。
 *
 * 约束：本脚本不修改上游源码，npm ci / 升级保持安全；stdout 只留给 MCP 协议，诊断信息一律写 stderr；
 * 任何输出不得包含凭证明文；空值、占位符（<...> 形态）、模板参考值（带 example.com / zhangsan / yourcompany
 * 等指纹）都视为未填写，拒绝启动（与 mcpctl 配置向导的就绪判定一致）。
 */

import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const TAG = "[jenkins-launcher]";
const KEY = "jenkins";
// 字段的中文名，与 scripts/lib/config-wizard.ps1 的字段目录保持一致
const LABELS = { enabled: "是否启用 Jenkins", baseUrl: "Jenkins 地址", username: "Jenkins 用户名", apiToken: "API Token" };

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

// 读取统一配置并返回 services.jenkins 配置段；任何问题都以中文说明退出
function loadSection() {
  const override = text(process.env.MCP_SUITE_CONFIG);
  // MCP_SUITE_CONFIG 约定为绝对路径；这里按绝对路径语义解析，避免受工作目录影响
  const configPath = override ? resolve(override) : join(here, "..", "mcp.config.json");
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
  fail(`Jenkins 已在统一配置中禁用（services.${KEY}.enabled 不是 true），不启动。`);
}
const baseUrl = text(section.baseUrl).replace(/\/+$/, "");
const username = text(section.username);
const apiToken = text(section.apiToken);

requireFilled("baseUrl", baseUrl);
if (!/^https?:\/\//i.test(baseUrl)) {
  fail(`统一配置 services.${KEY}.baseUrl（${LABELS.baseUrl}）格式不正确：需以 http:// 或 https:// 开头。`);
}
requireFilled("username", username);
requireFilled("apiToken", apiToken);

const entry = join(here, "node_modules", "jenkins-mcp-server", "src", "server", "mcp-server.js");
if (!existsSync(entry)) {
  fail(`上游服务缺失：${entry}\n下一步：运行 scripts/bootstrap.ps1（或在本目录执行 npm ci）安装锁定依赖后重试。`);
}

process.env.JENKINS_URL = baseUrl;
process.env.JENKINS_USERNAME = username;
process.env.JENKINS_API_TOKEN = apiToken;
if (section.readOnly === true) {
  console.error(`${TAG} 提示：readOnly=true。上游 jenkins-mcp-server 无内建只读模式，触发 / 停止构建等写操作不会被拦截。`);
}

const { JenkinsMcpServer } = await import(pathToFileURL(entry).href);
const server = new JenkinsMcpServer();
await server.start();
