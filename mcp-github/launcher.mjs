// Launcher for the official GitHub MCP server (stdio).
// Located via import.meta.url so the whole MCP tree stays relocatable.
// Reads .env (GITHUB_PAT -> GITHUB_PERSONAL_ACCESS_TOKEN, plus optional
// GITHUB_BASE_URL / GITHUB_SCOPE) and spawns bin/github-mcp-server.exe
// with stdio passed through unchanged. Never holds the token itself.
import { readFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const exe = path.join(here, "bin", "github-mcp-server.exe");
const envPath = path.join(here, ".env");

if (!existsSync(exe)) {
  console.error(`[github-launcher] 二进制缺失：${exe}`);
  console.error("[github-launcher] 下一步：运行 mcp-github/setup-github-mcp.ps1 下载锁定版本二进制后重试");
  process.exit(1);
}
if (!existsSync(envPath)) {
  console.error(`[github-launcher] 本地配置缺失：${envPath}`);
  console.error("[github-launcher] 下一步：复制 .env.template 为 .env 并填写 GITHUB_PAT 后重试（该文件已被 .gitignore 排除，不会入库）");
  process.exit(1);
}

const env = { ...process.env };
const isPlaceholder = (v) => /^\s*<.*>\s*$/.test(v);
for (const raw of readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const line = raw.trim();
  if (!line || line.startsWith("#") || !line.includes("=")) continue;
  const eq = line.indexOf("=");
  const key = line.slice(0, eq).trim();
  let value = line.slice(eq + 1).trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    value = value.slice(1, -1);
  }
  // <占位符> 形态视为未填写（与配置向导的就绪判定一致），不注入
  if (key && !isPlaceholder(value)) env[key] = value;
}

if (!env.GITHUB_PAT || isPlaceholder(env.GITHUB_PAT)) {
  console.error("[github-launcher] .env 中 GITHUB_PAT 为空或仍是占位符，请填写真实令牌后重试");
  process.exit(1);
}
// 官方二进制读取的是 GITHUB_PERSONAL_ACCESS_TOKEN，这里做一次映射，避免模板字段与官方变量耦合。
env.GITHUB_PERSONAL_ACCESS_TOKEN = env.GITHUB_PAT;
if (env.GITHUB_BASE_URL && !env.GITHUB_HOST && !isPlaceholder(env.GITHUB_BASE_URL)) {
  env.GITHUB_HOST = env.GITHUB_BASE_URL;
}

// v2.x requires an explicit subcommand; default to the stdio server.
const args = process.argv.slice(2);
if (args.length === 0) args.push("stdio");

const child = spawn(exe, args, { env, stdio: "inherit" });
child.on("error", (err) => {
  console.error(`[github-launcher] 启动失败：${err.message}`);
  process.exit(1);
});
child.on("exit", (code) => process.exit(code ?? 0));
