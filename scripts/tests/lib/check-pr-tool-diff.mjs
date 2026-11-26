#!/usr/bin/env node
// ai-mcp 升级工作流（T-FLOW-02）：PR 工具数变化校验。
//
// 比较基线提交与当前工作区 scripts/tests/cases/services.json 中每个服务的 expectedTools：
// 任一服务的变化幅度超过阈值（默认 ±20%）时，PR 描述必须粘贴「工具快照差异」摘要
// （scripts/tests/run-tests.bat --diff 的输出即含该关键字），缺失则退出码 1，PR 不能合并。
//
// 用法：node scripts/tests/lib/check-pr-tool-diff.mjs --base <提交> --body-file <PR 描述文件> [--threshold 20] [--cases <相对路径>]
// 退出码：0 通过（未超过阈值，或已附差异摘要）；1 需要摘要但缺失，或基线无法读取；3 参数错误。
// 新增服务（基线中没有）不在此校验，走《新增 MCP 服务工作流》。

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXIT = { PASS: 0, FAIL: 1, USAGE: 3 };
const KEYWORD = "工具快照差异";
const DEFAULT_CASES = "scripts/tests/cases/services.json";
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..", "..", "..");

function parseArgs(argv) {
  const out = { base: null, bodyFile: null, threshold: 20, cases: DEFAULT_CASES };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => { if (i + 1 >= argv.length) { throw new Error(`选项 ${a} 缺少取值`); } return argv[++i]; };
    if (a === "--base") { out.base = next(); }
    else if (a === "--body-file") { out.bodyFile = next(); }
    else if (a === "--threshold") { out.threshold = Number(next()); }
    else if (a === "--cases") { out.cases = next(); }
    else { throw new Error(`未知参数：${a}`); }
  }
  if (!out.base) { throw new Error("缺少 --base（PR 基线提交）"); }
  if (!out.bodyFile) { throw new Error("缺少 --body-file（PR 描述文件）"); }
  if (!(out.threshold > 0 && out.threshold <= 100)) { throw new Error("--threshold 须为 0–100 之间的百分数"); }
  return out;
}

function git(args) {
  const r = spawnSync("git", ["-C", REPO, "-c", "core.quotepath=off", ...args], { encoding: "buffer", windowsHide: true });
  return { status: r.status, text: Buffer.from(r.stdout ?? []).toString("utf8"), error: Buffer.from(r.stderr ?? []).toString("utf8") };
}
function shortSha(ref) { const r = git(["rev-parse", "--short=7", `${ref}^{commit}`]); return r.status === 0 ? r.text.trim() : String(ref).slice(0, 7); }

function loadCases(text, label) {
  let doc;
  try { doc = JSON.parse(text.replace(/^\uFEFF/, "")); } catch (e) { throw new Error(`${label} 的用例文件不是合法 JSON：${e.message}`); }
  const list = Array.isArray(doc) ? doc : doc?.services;
  if (!Array.isArray(list)) { throw new Error(`${label} 的用例文件没有 services 数组`); }
  const map = new Map();
  for (const c of list) {
    if (c && typeof c.id === "string" && Number.isInteger(c.expectedTools)) { map.set(c.id, c.expectedTools); }
  }
  return map;
}

function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (e) { console.log(`参数错误：${e.message}`); return EXIT.USAGE; }
  if (!existsSync(opts.bodyFile)) { console.log(`参数错误：PR 描述文件不存在：${opts.bodyFile}`); return EXIT.USAGE; }

  // 基线提交不在本地历史时按提交号浅取一次（CI 的检出是完整历史，通常用不到）
  if (git(["cat-file", "-e", `${opts.base}^{commit}`]).status !== 0) {
    git(["fetch", "--quiet", "--depth=1", "origin", opts.base]);
  }
  const baseShow = git(["show", `${opts.base}:${opts.cases}`]);
  const baseSha = shortSha(opts.base);
  if (baseShow.status !== 0) {
    console.log(`::error::无法读取基线提交 ${baseSha} 的 ${opts.cases}，工具数变化校验未完成：${baseShow.error.trim().split(/\r?\n/)[0]}`);
    return EXIT.FAIL;
  }
  let baseCases;
  let headCases;
  try {
    baseCases = loadCases(baseShow.text, `基线 ${baseSha}`);
    headCases = loadCases(readFileSync(path.join(REPO, opts.cases), "utf8"), "当前工作区");
  } catch (e) { console.log(`::error::${e.message}`); return EXIT.FAIL; }

  const rows = [];
  for (const [id, now] of headCases) {
    const before = baseCases.get(id);
    if (before === undefined) { continue; }
    const change = before > 0 ? Math.abs(now - before) / before : 1;
    rows.push({ id, before, now, change });
  }
  const pct = (x) => `${x >= 0 ? "+" : "-"}${(Math.abs(x) * 100).toFixed(1)}%`;
  const describe = (r) => `${r.id} ${r.before} → ${r.now}（${pct((r.now - r.before) / r.before)}）`;
  const need = rows.filter((r) => r.change > opts.threshold / 100);
  const changed = rows.filter((r) => r.now !== r.before);

  if (need.length === 0) {
    if (changed.length) { console.log(`工具数有变化但未超过 ±${opts.threshold}%，无需差异摘要：${changed.map(describe).join("；")}`); }
    else { console.log(`工具数未变化，无需差异摘要（已对比基线 ${baseSha}）`); }
    return EXIT.PASS;
  }
  const body = readFileSync(opts.bodyFile, "utf8");
  if (body.includes(KEYWORD)) {
    console.log(`工具数变化超过 ±${opts.threshold}%，PR 描述已附「${KEYWORD}」摘要：${need.map(describe).join("；")}`);
    return EXIT.PASS;
  }
  for (const r of need) { console.log(`::error::工具数变化超过 ±${opts.threshold}%：${describe(r)}`); }
  console.log(`::error::PR 描述缺少「${KEYWORD}」摘要。请运行 scripts\\tests\\run-tests.bat --diff，把输出中的「新增 / 删除 / 签名变化」清单粘贴到 PR 描述（须包含「${KEYWORD}」字样）；升级流程见 docs/planning/升级MCP服务工作流.md`);
  return EXIT.FAIL;
}

process.exitCode = main();
