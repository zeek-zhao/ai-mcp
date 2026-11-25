/**
 * mcp-jenkins 本地启动器（模型一：由 Host 按需 stdio 拉起，本进程生命周期完全由 Host 管理）。
 *
 * 职责：
 *   1. 读取同目录 jenkins_config.json（本地真实配置，已被 .gitignore 排除，绝不入库）；
 *   2. 将其映射为 jenkins-mcp-server 需要的环境变量：
 *        baseUrl  -> JENKINS_URL
 *        username -> JENKINS_USERNAME
 *        apiToken -> JENKINS_API_TOKEN（留空则上游以匿名只读方式访问）
 *   3. 动态 import 上游服务入口并启动（绕过其 validateConfig 的环境变量强校验）。
 *
 * 注意：上游 import 必须是动态的。ES module 的静态 import 会被提升并在任何
 * 顶层语句之前求值，若静态 import，环境变量会在配置注入前被读取。
 *
 * 本脚本不修改上游源码，npm ci / 升级保持安全。
 * 占位符（<...> 形态）视为未填写，直接拒绝启动（与配置向导的就绪判定一致）。
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const configPath = process.env.MCP_JENKINS_CONFIG_FILE || join(here, "jenkins_config.json");

if (!existsSync(configPath)) {
  console.error(`[jenkins-launcher] 本地配置缺失：${configPath}`);
  console.error("[jenkins-launcher] 下一步：复制 jenkins_config.sample.json 为 jenkins_config.json 并填写后重试（该文件已被 .gitignore 排除，不会入库）");
  process.exit(1);
}

const isPlaceholder = (v) => /^\s*<.*>\s*$/.test(v);
let cfg;
try {
  cfg = JSON.parse(readFileSync(configPath, "utf8"));
} catch (err) {
  console.error(`[jenkins-launcher] 配置解析失败：${err.message}`);
  process.exit(1);
}

const baseUrl = String(cfg.baseUrl || "").trim();
const username = String(cfg.username || "").trim();
const apiToken = String(cfg.apiToken || "").trim();

if (!baseUrl || isPlaceholder(baseUrl)) {
  console.error("[jenkins-launcher] jenkins_config.json 中 baseUrl 为空或仍是占位符，请填写真实实例地址后重试");
  process.exit(1);
}
if (apiToken && isPlaceholder(apiToken)) {
  console.error("[jenkins-launcher] jenkins_config.json 中 apiToken 仍是占位符，请填写真实 API Token（或删除该字段以匿名只读访问）");
  process.exit(1);
}

if (baseUrl) process.env.JENKINS_URL = baseUrl;
if (username) process.env.JENKINS_USERNAME = username;
if (apiToken) process.env.JENKINS_API_TOKEN = apiToken;

const entry = join(here, "node_modules", "jenkins-mcp-server", "src", "server", "mcp-server.js");
if (!existsSync(entry)) {
  console.error(`[jenkins-launcher] 上游服务缺失：${entry}`);
  console.error("[jenkins-launcher] 下一步：运行 scripts/bootstrap.ps1（或在本目录执行 npm ci）安装锁定依赖后重试");
  process.exit(1);
}

const { JenkinsMcpServer } = await import(pathToFileURL(entry).href);
const server = new JenkinsMcpServer();
await server.start();
