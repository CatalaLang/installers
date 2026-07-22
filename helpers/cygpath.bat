@echo off
:parse
if "%~1"=="-w" ( shift & goto parse )
if "%~1"=="-m" ( shift & goto parse )
if "%~1"=="-u" ( shift & goto parse )
if "%~1"=="-a" ( shift & goto parse )
if "%~1"=="-p" ( shift & goto parse )
if not "%~1"=="" echo %~1
