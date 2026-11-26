// ai-mcp self tests helper (T-FLOW-01). Prints the config keys (one line, space separated) that
// scripts/tests/run-tests.bat should execute, taken from scripts/tests/cases/services.json.
// Options --service <Id|配置段名|mcp-配置段名> and --only a,b are honoured with the same selector
// rules as lib/mcp-stdio-test.mjs; other options are ignored here (they are validated by the core).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const KEY_PATTERN = /^[a-z][a-z0-9]*$/;

function fail(message) {
  console.error(`[list-case-keys] ${message}`);
  process.exit(1);
}

let cases;
try {
  const doc = JSON.parse(readFileSync(join(here, "..", "cases", "services.json"), "utf8").replace(/^\uFEFF/, ""));
  cases = Array.isArray(doc.services) ? doc.services : null;
} catch (e) {
  fail(`无法读取 scripts/tests/cases/services.json（${e?.message ?? e}）`);
}
if (!cases || cases.length === 0) { fail("scripts/tests/cases/services.json 没有 services 数组"); }
for (const item of cases) {
  const key = String(item?.configKey ?? "");
  if (!KEY_PATTERN.test(key)) { fail(`用例 configKey 不合法：${key || "(空)"}（须匹配 ${KEY_PATTERN}）`); }
}
const selectorOf = (c) => [c.id, c.configKey, `mcp-${c.configKey}`];
const selectedBy = (x) => cases.filter((c) => selectorOf(c).includes(x));

const argv = process.argv.slice(2);
let service = null;
let only = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--service" && i + 1 < argv.length) { service = argv[++i]; }
  else if (argv[i] === "--only" && i + 1 < argv.length) { only = String(argv[++i]).split(",").map((s) => s.trim()).filter(Boolean); }
}
let selected = cases;
if (service !== null) {
  selected = selectedBy(service);
  if (selected.length === 0) { fail(`--service ${service} 没有对应用例`); }
}
if (only !== null) {
  const unknown = only.filter((x) => selectedBy(x).length === 0);
  if (unknown.length > 0) { fail(`--only 中的 ${unknown.join("、")} 没有对应用例`); }
  const wanted = new Set(only.flatMap((x) => selectedBy(x).map((c) => c.id)));
  selected = selected.filter((c) => wanted.has(c.id));
}
const keys = selected.map((c) => c.configKey);
if (keys.length > 0) { process.stdout.write(keys.join(" ")); }
