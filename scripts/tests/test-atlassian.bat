@echo off
chcp 65001 >nul
rem Self test for mcp-atlassian (Jira + Confluence). All options are forwarded to lib\mcp-stdio-test.mjs.
node "%~dp0lib\mcp-stdio-test.mjs" --service mcp-atlassian %*
exit /b %errorlevel%
