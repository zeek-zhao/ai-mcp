# -*- coding: utf-8 -*-
"""mcp-atlassian 本地启动器（模型一：由 Host 按需 stdio 拉起，本进程生命周期完全由 Host 管理）。

配置来源：仓库根统一配置 mcp.config.json 的 services.atlassian 配置段。
    路径优先取环境变量 MCP_SUITE_CONFIG（绝对路径），未设置时回退到 <本服务目录>/../mcp.config.json。

字段映射（环境变量名以 mcp-atlassian==0.23.1 为准；升级上游后必须重新核对其 README 与 config.py）：
    deployment          -> cloud：登录邮箱 + API Token；server：个人访问令牌（PAT）
    jiraBaseUrl         -> JIRA_URL
    confluenceBaseUrl   -> CONFLUENCE_URL
    email               -> JIRA_USERNAME / CONFLUENCE_USERNAME（仅 cloud）
    personalAccessToken -> cloud：JIRA_API_TOKEN + CONFLUENCE_API_TOKEN
                           server：JIRA_PERSONAL_TOKEN + CONFLUENCE_PERSONAL_TOKEN
    confluencePersonalAccessToken（可选）
                         -> 仅作用于 Confluence：cloud 写入 CONFLUENCE_API_TOKEN，server 写入 CONFLUENCE_PERSONAL_TOKEN；
                            留空时 Confluence 沿用 personalAccessToken
    projectScope[]      -> JIRA_PROJECTS_FILTER（逗号分隔）
    spaceScope[]        -> CONFLUENCE_SPACES_FILTER（逗号分隔）

启动方式：进程内调用上游 stdio 主循环（不产生子进程，Host 结束本进程即完整退出）。
安全约束：stdout 只留给 MCP 协议，诊断信息一律写 stderr；任何输出不得包含凭证明文；
空值、占位符（<...> 形态）、模板参考值（带 example.com / zhangsan / yourcompany 等指纹）都视为未填写，
直接拒绝启动（与 mcpctl 配置向导的就绪判定一致）。
"""

import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEY = "atlassian"
TAG = "[atlassian-launcher]"
DEPLOYMENTS = ("cloud", "server")
# 模板参考值指纹：关键词必须与 scripts/lib/suite-config.ps1 的 $script:McpSuiteTemplateValuePattern 一致（CI 校验）
TEMPLATE_VALUE_PATTERN = re.compile(r"example\.com|example\.net|yourcompany|zhangsan|your-name|your-company", re.IGNORECASE)
# 字段的中文名，与 scripts/lib/config-wizard.ps1 的字段目录保持一致
LABELS = {
    "enabled": "是否启用 Atlassian（Jira + Confluence）",
    "deployment": "部署类型（cloud / server）",
    "jiraBaseUrl": "Jira 地址",
    "confluenceBaseUrl": "Confluence 地址",
    "email": "登录邮箱",
    "personalAccessToken": "访问令牌（Cloud 填 API Token，Server 填 PAT）",
    "confluencePersonalAccessToken": "Confluence 专用令牌（可选，留空则沿用访问令牌）",
}


def fail(message: str) -> None:
    print(f"{TAG} {message}", file=sys.stderr)
    sys.exit(1)


def is_placeholder(value: str) -> bool:
    v = value.strip()
    return v.startswith("<") and v.endswith(">")


def unfilled_text(value: str):
    """值未填写时返回中文说明（空值 / 占位符 / 模板参考值分开提示，与 mcpctl 的就绪判定文案一致）；已填写返回 None。

    只给出命中的指纹关键词（如 example.com），不回显字段值。
    """
    if not value:
        return "未填写，请填写"
    if is_placeholder(value):
        return "仍是占位符，需填写真实值"
    match = TEMPLATE_VALUE_PATTERN.search(value)
    if match:
        return f"仍是模板参考值（特征：{match.group(0).lower()}），需替换为真实值"
    return None


def text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value).strip()


def as_csv(values) -> str:
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, (list, tuple)):
        return ""
    return ",".join(str(v).strip() for v in values if str(v).strip())


def load_section() -> dict:
    override = os.environ.get("MCP_SUITE_CONFIG", "").strip()
    config_path = Path(override) if override else HERE.parent / "mcp.config.json"
    if not config_path.is_file():
        fail(
            f"统一配置文件不存在：{config_path}\n"
            "下一步：运行 mcpctl 配置向导（scripts/mcpctl.ps1 菜单 4）从模板生成 mcp.config.json 并填写。"
        )
    try:
        raw = config_path.read_text(encoding="utf-8-sig")
    except OSError as err:
        fail(f"统一配置文件读取失败：{config_path}（{type(err).__name__}）")
    try:
        doc = json.loads(raw)
    except ValueError as err:
        # 只给出行列号，不回显解析器原文（可能夹带配置内容）
        fail(
            f"统一配置不是合法 JSON：{config_path}（第 {getattr(err, 'lineno', '?')} 行，"
            f"第 {getattr(err, 'colno', '?')} 列附近）。请检查引号、逗号与括号是否成对。"
        )
    if not isinstance(doc, dict):
        fail(f"统一配置的顶层必须是 JSON 对象：{config_path}")
    if doc.get("configVersion") != 1:
        fail(f"统一配置的 configVersion 不受支持：{config_path}（当前仅支持 1）")
    services = doc.get("services")
    if not isinstance(services, dict):
        fail(f"统一配置缺少 services 配置段，或该段不是对象：{config_path}（请对照 mcp.config.sample.json 补全）")
    section = services.get(KEY)
    if not isinstance(section, dict):
        fail(f"统一配置缺少 services.{KEY} 配置段：{config_path}（请对照 mcp.config.sample.json 补全）")
    return section


def require_filled(section: dict, name: str, url: bool = False) -> str:
    value = text(section.get(name))
    issue = unfilled_text(value)
    if issue:
        fail(f"统一配置 services.{KEY}.{name}（{LABELS[name]}）{issue}。")
    if url and not value.lower().startswith(("http://", "https://")):
        fail(f"统一配置 services.{KEY}.{name}（{LABELS[name]}）格式不正确：需以 http:// 或 https:// 开头。")
    return value


def optional_filled(section: dict, name: str) -> str:
    """可选字段：未填写返回空串；填了占位符或模板参考值则拒绝启动（与必填字段同一套文案）。"""
    value = text(section.get(name))
    if not value:
        return ""
    issue = unfilled_text(value)
    if issue:
        fail(f"统一配置 services.{KEY}.{name}（{LABELS[name]}）{issue}，或清空以沿用 personalAccessToken。")
    return value


def main() -> None:
    # 管道 / 重定向下按 UTF-8 输出中文诊断（否则 Windows 默认用本地代码页，Host 侧会乱码）
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    section = load_section()
    if section.get("enabled") is not True:
        fail(f"Atlassian（Jira + Confluence）已在统一配置中禁用（services.{KEY}.enabled 不是 true），不启动。")

    deployment = require_filled(section, "deployment")
    if deployment not in DEPLOYMENTS:
        fail(f"统一配置 services.{KEY}.deployment（{LABELS['deployment']}）只能是 cloud 或 server，当前无法识别。")
    jira_url = require_filled(section, "jiraBaseUrl", url=True).rstrip("/")
    conf_url = require_filled(section, "confluenceBaseUrl", url=True).rstrip("/")
    token = require_filled(section, "personalAccessToken")
    # Confluence 专用令牌（可选）：留空则沿用访问令牌
    confluence_token = optional_filled(section, "confluencePersonalAccessToken") or token

    os.environ["JIRA_URL"] = jira_url
    os.environ["CONFLUENCE_URL"] = conf_url
    if deployment == "cloud":
        email = require_filled(section, "email")
        os.environ["JIRA_USERNAME"] = email
        os.environ["CONFLUENCE_USERNAME"] = email
        os.environ["JIRA_API_TOKEN"] = token
        os.environ["CONFLUENCE_API_TOKEN"] = confluence_token
        # 同一进程里不残留另一种部署类型的变量，避免切换部署类型后互相干扰
        for name in ("JIRA_PERSONAL_TOKEN", "CONFLUENCE_PERSONAL_TOKEN"):
            os.environ.pop(name, None)
    else:
        os.environ["JIRA_PERSONAL_TOKEN"] = token
        os.environ["CONFLUENCE_PERSONAL_TOKEN"] = confluence_token
        for name in ("JIRA_USERNAME", "CONFLUENCE_USERNAME", "JIRA_API_TOKEN", "CONFLUENCE_API_TOKEN"):
            os.environ.pop(name, None)

    projects = as_csv(section.get("projectScope"))
    spaces = as_csv(section.get("spaceScope"))
    os.environ["JIRA_PROJECTS_FILTER"] = projects
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
