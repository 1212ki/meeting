@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "ARGS="

:build_args
if "%~1"=="" goto run
set "arg=%~1"
if "%arg:~0,2%"=="--" set "arg=-%arg:~2%"
set "ARGS=%ARGS% "%arg%""
shift
goto build_args

:run
if defined MEETING_DEBUG_ARGS echo DEBUG meeting.cmd ARGS=%ARGS%
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%meeting.ps1" %ARGS%
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%meeting.ps1" %ARGS%
)

exit /b %ERRORLEVEL%
