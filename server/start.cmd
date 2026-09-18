@echo off
rem ---------------------------------------------------------------------------
rem  ZAOJI server launcher  (double-click to run)
rem
rem  Why a .cmd and not a .ps1:
rem  the execution policy on this machine is Restricted, so a .ps1 cannot be
rem  double-clicked. A .cmd always can. No arguments needed for normal use.
rem
rem  The exe resolves data\ and certs\ relative to ITS OWN folder, so this file
rem  works no matter which directory you happen to be in, and it also works when
rem  the whole server\ folder is copied to another machine.
rem ---------------------------------------------------------------------------

chcp 65001 >nul
cd /d "%~dp0"

if not exist "%~dp0zaoji_server.exe" (
  echo.
  echo   zaoji_server.exe not found in "%~dp0"
  echo   Build it first:
  echo     dart compile exe bin\zaoji_server.dart -o zaoji_server.exe
  echo.
  pause
  exit /b 1
)

"%~dp0zaoji_server.exe" %*

echo.
echo   Server stopped.  Press any key to close this window.
pause >nul
