@echo off
setlocal
title XCall Demo Portal
cd /d "%~dp0.."

set PHP=tools\php\php.exe
set PORT=8080

if not exist "%PHP%" (
  echo [xcall] PHP not found at %PHP%
  echo [xcall] Download it: https://windows.php.net/downloads/releases/php-8.4.24-nts-Win32-vs17-x64.zip
  echo [xcall] Extract it to tools\php\ and re-run this script.
  exit /b 1
)

echo [xcall] preparing local dev shims ...
if not exist resources mkdir resources
copy /y local\resources-shim.php resources\require.php >nul
if not exist portal\resources mkdir portal\resources
copy /y local\webphone-require.tpl.php portal\resources\require.php >nul

echo [xcall] starting XCall portal on http://127.0.0.1:%PORT%/
start "XCall Portal (local demo)" /b "%PHP%" -c local\php.ini -S 127.0.0.1:%PORT% -t portal local\dev-router.php > local\server.log 2>&1
timeout /t 2 >nul

echo.
echo   Portal            : http://127.0.0.1:%PORT%/
echo   AI Assistants     : http://127.0.0.1:%PORT%/ai-assistant/assistants.php
echo   Web Softphone     : http://127.0.0.1:%PORT%/webphone/index.html
echo   API list          : http://127.0.0.1:%PORT%/ai-assistant/assistant_api.php?action=list
echo.
echo   Stop with:  local\stop-demo.bat   (or close the server window)
echo.
endlocal
