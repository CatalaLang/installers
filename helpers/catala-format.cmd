@echo off
:: catala bundle wrapper for catala-format
setlocal
for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "TC=%BASE%\toolchain"
set "XDG_CACHE_HOME=%TC%\share"
set "PATH=%TC%\bin\.topiary-wrapped;%TC%\bin;%PATH%"
"%TC%\bin\catala-format.exe" %*
exit /b %ERRORLEVEL%
