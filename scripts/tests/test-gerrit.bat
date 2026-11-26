@echo off
chcp 65001 >nul
rem Self test for mcp-gerrit. All options are forwarded to lib\mcp-stdio-test.mjs.
node "%~dp0lib\mcp-stdio-test.mjs" --service mcp-gerrit %*
exit /b %errorlevel%
