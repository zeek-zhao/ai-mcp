# -*- coding: utf-8 -*-
"""mcp-gerrit 本地启动器（模型一：由 Host 按需 stdio 拉起，本进程生命周期完全由 Host 管理）。

配置来源：仓库根统一配置 mcp.config.json 的 services.gerrit 配置段。
    路径优先取环境变量 MCP_SUITE_CONFIG（绝对路径）；其次取环境变量 MCP_SUITE_ROOT（仓库根目录）下的
    mcp.config.json；两者都未设置时回退到 <本服务目录>/../mcp.config.json。
    MCP_SUITE_ROOT 已设置但无效时报错退出、不回退（判定与文案与 scripts/lib/registry.ps1 一致）。

为什么需要本启动器：上游 gerrit-mcp-server 只接受它自己的「配置文件」方式（--config <path>），
配置结构是嵌套 JSON（gerrit_hosts[].authentication），与统一配置的扁平字段不一致。本启动器把
services.gerrit 合成为上游格式，写到 <仓库根>/var/tmp/gerrit-config-<pid>.json，再以标准流继承的
方式拉起上游进程：gerrit-mcp-server --config <临时文件> stdio。

临时文件处置：
    - 上游进程退出（含异常路径）时立即删除；
    - 启动时顺带清理以往异常退出遗留、且属主进程已不存在的临时文件；
    - <仓库根>/var/ 已被 .gitignore 排除，不会入库。

安全约束：stdout 只留给 MCP 协议，诊断信息一律写 stderr；任何输出不得包含凭证明文；
空值、占位符（<...> 形态）、模板参考值（带 example.com / zhangsan / yourcompany 等指纹）都视为未填写，
直接拒绝启动（与 mcpctl 配置向导的就绪判定一致）。
"""

import ctypes
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
TMP_DIR = REPO_ROOT / "var" / "tmp"
TMP_PATTERN = re.compile(r"gerrit-config-(\d+)\.json")
KEY = "gerrit"
TAG = "[gerrit-launcher]"
# 模板参考值指纹：关键词必须与 scripts/lib/suite-config.ps1 的 $script:McpSuiteTemplateValuePattern 一致（CI 校验）
TEMPLATE_VALUE_PATTERN = re.compile(r"example\.com|example\.net|yourcompany|zhangsan|your-name|your-company", re.IGNORECASE)
# 字段的中文名，与 scripts/lib/config-wizard.ps1 的字段目录保持一致
LABELS = {
    "enabled": "是否启用 Gerrit",
    "baseUrl": "Gerrit 实例地址",
    "instanceName": "显示名称",
    "username": "Gerrit 用户名",
    "httpPassword": "HTTP 凭证（HTTP 密码）",
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
    return "" if value is None else str(value).strip()


ROOT_ENV_NAME = "MCP_SUITE_ROOT"
ROOT_CLEAR_COMMAND = 'setx MCP_SUITE_ROOT ""'


def resolve_config_path() -> Path:
    """定位统一配置：MCP_SUITE_CONFIG > MCP_SUITE_ROOT/mcp.config.json > <本服务目录>/../mcp.config.json。"""
    override = os.environ.get("MCP_SUITE_CONFIG", "").strip()
    if override:
        return Path(override)
    root_env = os.environ.get(ROOT_ENV_NAME, "").strip()
    if root_env:
        # 与 scripts/lib/registry.ps1 的判定和报错文案保持逐字一致；无效时不回退
        if not os.path.isabs(root_env):
            fail(f"环境变量 MCP_SUITE_ROOT 必须是仓库根目录的绝对路径，当前为：{root_env}。请改为正确的仓库根目录，或清除该变量后重试：{ROOT_CLEAR_COMMAND}")
        if not (Path(root_env) / "scripts" / "mcpctl.config.ps1").is_file():
            fail(f"环境变量 MCP_SUITE_ROOT 指向的目录不是本仓库根（缺少 scripts/mcpctl.config.ps1）：{root_env}。请改为正确的仓库根目录，或清除该变量后重试：{ROOT_CLEAR_COMMAND}")
        return Path(root_env) / "mcp.config.json"
    return REPO_ROOT / "mcp.config.json"


def load_section() -> dict:
    config_path = resolve_config_path()
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


def find_server_exe() -> Path:
    if os.name == "nt":
        return HERE / "venv" / "Scripts" / "gerrit-mcp-server.exe"
    return HERE / "venv" / "bin" / "gerrit-mcp-server"


def pid_alive(pid: int) -> bool:
    """判断进程是否仍在运行（Windows 用 OpenProcess；不能用 os.kill(pid, 0)，它在 Windows 上会终止进程）。"""
    if pid <= 0:
        return False
    if os.name == "nt":
        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        still_active = 259
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            # 5 = ERROR_ACCESS_DENIED：进程存在，只是无权查询
            return kernel32.GetLastError() == 5
        try:
            code = ctypes.c_ulong()
            ok = kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
            return bool(ok) and code.value == still_active
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cleanup_stale(own: Path) -> int:
    """删除属主进程已不存在的遗留临时文件；返回删除数量。"""
    removed = 0
    if not TMP_DIR.is_dir():
        return 0
    for item in TMP_DIR.iterdir():
        match = TMP_PATTERN.fullmatch(item.name)
        if not match or item == own:
            continue
        try:
            if pid_alive(int(match.group(1))):
                continue
            item.unlink()
            removed += 1
        except OSError:
            continue
    return removed


def main() -> None:
    # 管道 / 重定向下按 UTF-8 输出中文诊断（否则 Windows 默认用本地代码页，Host 侧会乱码）
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    section = load_section()
    if section.get("enabled") is not True:
        fail(f"Gerrit 已在统一配置中禁用（services.{KEY}.enabled 不是 true），不启动。")

    base_url = require_filled(section, "baseUrl", url=True).rstrip("/")
    username = require_filled(section, "username")
    http_password = require_filled(section, "httpPassword")
    instance_name = text(section.get("instanceName")) or base_url.split("//", 1)[-1]

    exe = find_server_exe()
    if not exe.is_file():
        fail(
            f"上游服务缺失：{exe}\n"
            "下一步：运行 scripts/bootstrap.ps1（或在服务目录 venv 内执行 "
            "pip install -r mcp-gerrit/requirements.txt）安装锁定依赖后重试"
        )

    # 合成为上游 gerrit-mcp-server 的配置结构（instances 为预留字段，当前只接入 baseUrl 这一个实例）
    payload = {
        "default_gerrit_base_url": base_url,
        "gerrit_hosts": [
            {
                "name": instance_name,
                "external_url": base_url,
                "authentication": {"type": "http_basic", "username": username, "auth_token": http_password},
            }
        ],
    }

    try:
        TMP_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as err:
        fail(f"无法创建临时配置目录：{TMP_DIR}（{type(err).__name__}）")
    own = TMP_DIR / f"gerrit-config-{os.getpid()}.json"
    cleanup_stale(own)
    try:
        # 上游按系统默认编码读取配置文件（中文 Windows 为 GBK），因此临时文件只写 ASCII（非 ASCII 字符转为 \uXXXX 转义）
        fd = os.open(str(own), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            json.dump(payload, handle, ensure_ascii=True, indent=2)
    except OSError as err:
        fail(f"无法写入临时配置：{own}（{type(err).__name__}）")

    command = [str(exe), "--config", str(own), "stdio"]
    print(f"{TAG} 已拉起上游服务，临时配置：{own}（退出后自动删除）", file=sys.stderr, flush=True)
    try:
        proc = subprocess.Popen(command)  # 标准流全部继承：stdio 通道原样交给上游
        try:
            return_code = proc.wait()
        except KeyboardInterrupt:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            raise
    finally:
        try:
            own.unlink()
        except OSError:
            pass
    # 上游以信号终止（返回码为负）时按失败退出，其余透传
    if return_code is None or return_code < 0:
        sys.exit(1)
    sys.exit(return_code)


if __name__ == "__main__":
    main()
