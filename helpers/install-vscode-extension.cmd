@echo off
setlocal
set "VSIX="
for %%F in ("%~dp0catala-*.vsix") do set "VSIX=%%~fF"
if not defined VSIX (
  echo No Catala .vsix found next to this script.
  pause & exit /b 1
)
where code >nul 2>nul || (echo VS Code 'code' command not found on PATH -- install VS Code first. & pause & exit /b 1)
echo Installing the Catala VS Code extension from:
echo   %VSIX%
call code --install-extension "%VSIX%"
echo.
echo Done. Restart VS Code to activate the extension.
pause
