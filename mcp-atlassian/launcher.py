# -*- coding: utf-8 -*-
"""mcp-atlassian 本地启动器（模型一：由 Host 按需 stdio 拉起，本进程生命周期完全由 Host 管理）。

用法（Host 的 MCP 条目）：
    command: <仓库>/mcp-atlassian/venv/Scripts/python.exe
    args:    ["<仓库>/mcp-atlassian/launcher.py"]

职责：
    1. 读取同目录 atlassian_config.json（本地真实配置，已被 .gitignore 排除，绝不入库）；
    2. 映射为 mcp-atlassian 的环境变量（Jira 与 Confluence 命名空间独立）：
           jiraBaseUrl        -> JIRA_URL
           confluenceBaseUrl  -> CONFLUENCE_URL
           personalAccessToken-> JIRA_PERSONAL_TOKEN + CONFLUENCE_PERSONAL_TOKEN
           projectScope[]     -> JIRA_PROJECTS_FILTER（逗号分隔）
           spaceScope[]       -> CONFLUENCE_SPACES_FILTER（逗号分隔）
    3. 进程内启动上游 stdio 主循环（不产生子进程，Host 结束本进程即完整退出）。

安全约束：占位符（<...> 形态）视为未填写，直接拒绝启动（与配置向导的就绪判定一致）；
任何输出不得包含明文凭证。
"""

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("MCP_ATLASSIAN_CONFIG_FILE", HERE / "atlassian_config.json"))


def fail(message: str) -> None:
    print(f"[atlassian-launcher] {message}", file=sys.stderr)
    sys.exit(1)


def is_placeholder(value: str) -> bool:
    v = value.strip()
    return v.startswith("<") and v.endswith(">")


def as_csv(values) -> str:
    parts = [str(v).strip() for v in values if str(v).strip()]
    return ",".join(parts)


def main() -> None:
    if not CONFIG_PATH.exists():
        fail(
            f"本地配置缺失：{CONFIG_PATH}\n"
            "下一步：复制 atlassian_config.sample.json 为 atlassian_config.json 并填写后重试"
            "（该文件已被 .gitignore 排除，不会入库）"
        )
    try:
        cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (ValueError, OSError) as err:
        fail(f"配置解析失败：{err}")

    jira_url = str(cfg.get("jiraBaseUrl", "") or "").strip()
    conf_url = str(cfg.get("confluenceBaseUrl", "") or "").strip()
    token = str(cfg.get("personalAccessToken", "") or "").strip()

    if not jira_url or is_placeholder(jira_url):
        fail("atlassian_config.json 中 jiraBaseUrl 为空或仍是占位符，请填写真实实例地址后重试")
    if not conf_url or is_placeholder(conf_url):
        fail("atlassian_config.json 中 confluenceBaseUrl 为空或仍是占位符，请填写真实实例地址后重试")
    if not token or is_placeholder(token):
        fail("atlassian_config.json 中 personalAccessToken 为空或仍是占位符，请填写真实令牌后重试")

    os.environ["JIRA_URL"] = jira_url
    os.environ["CONFLUENCE_URL"] = conf_url
    os.environ["JIRA_PERSONAL_TOKEN"] = token
    os.environ["CONFLUENCE_PERSONAL_TOKEN"] = token
    projects = as_csv(cfg.get("projectScope", []) or [])
    spaces = as_csv(cfg.get("spaceScope", []) or [])
    if projects:
        os.environ["JIRA_PROJECTS_FILTER"] = projects
    if spaces:
        os.environ["CONFLUENCE_SPACES_FILTER"] = spaces

    try:
        from mcp_atlassian import main as upstream_main
    except ImportError:
        fail(
            "上游服务缺失：无法 import mcp_atlassian\n"
            "下一步：运行 scripts/bootstrap.ps1（或在服务目录 venv 内执行 "
            "pip install -r mcp-atlassian/requirements.txt）安装锁定依赖后重试"
        )

    upstream_main()


if __name__ == "__main__":
    main()
