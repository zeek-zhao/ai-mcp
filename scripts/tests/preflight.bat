@echo off
chcp 65001 >nul
rem Environment preflight: node, dependency environments, unified config readiness, gateway reachability.
rem Prints no configuration values. Exit codes: 0 all selected services runnable, 2 something is blocked, 3 usage error.
node "%~dp0lib\mcp-stdio-test.mjs" --preflight %*
exit /b %errorlevel%
