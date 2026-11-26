@echo off
chcp 65001 >nul
setlocal EnableExtensions
rem ai-mcp self tests (T-TEST-01). Runs the test-<configKey>.bat of every case in cases\services.json and aggregates.
rem Exit codes: 0 PASS, 1 FAIL (worst), 2 BLOCKED, 3 USAGE. Precedence: FAIL > BLOCKED > USAGE.
rem Usage: scripts\tests\run-tests.bat [--structural] [--via gateway] [--gateway-url URL] [--gateway-agent NAME]
rem        [--config PATH] [--expect-tools N] [--service ID] [--only id,id] [--timeout-ms N] [--help]
set "HERE=%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo [run-tests] node not found in PATH. Overall exit code 2 = BLOCKED.
  exit /b 2
)
set "HAS_FAIL="
set "HAS_BLOCK="
set "HAS_USAGE="
echo %* | findstr /i /c:"--structural" >nul
if not errorlevel 1 goto tests
call "%HERE%preflight.bat" %*
if errorlevel 3 exit /b 3
:tests
rem Service list comes from cases\services.json (config keys, space separated); --service / --only narrow it.
rem A new service is picked up automatically once its case and test-<configKey>.bat exist.
set "KEYS="
for /f "usebackq delims=" %%K in (`node "%HERE%lib\list-case-keys.mjs" %* 2^>nul`) do set "KEYS=%%K"
if not defined KEYS (
  echo [run-tests] no runnable case in scripts\tests\cases\services.json for the given --service / --only, or the file is unreadable. Overall exit code 3 = USAGE.
  exit /b 3
)
for %%S in (%KEYS%) do (
  if not exist "%HERE%test-%%S.bat" (
    echo [run-tests] missing scripts\tests\test-%%S.bat for case "%%S". Overall exit code 1 = FAIL.
    set "HAS_FAIL=1"
  ) else (
    call "%HERE%test-%%S.bat" %*
    if errorlevel 3 (set "HAS_USAGE=1") else if errorlevel 2 (set "HAS_BLOCK=1") else if errorlevel 1 (set "HAS_FAIL=1")
  )
)
if defined HAS_FAIL (
  echo [run-tests] overall exit code 1 = FAIL
  exit /b 1
)
if defined HAS_BLOCK (
  echo [run-tests] overall exit code 2 = BLOCKED
  exit /b 2
)
if defined HAS_USAGE (
  echo [run-tests] overall exit code 3 = USAGE
  exit /b 3
)
echo [run-tests] overall exit code 0 = PASS
exit /b 0
