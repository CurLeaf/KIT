@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

set "PORT=%~1"

if "%PORT%"=="" (
    echo 用法: kill_port.bat [端口号]
    pause
    exit /b
)

set FOUND=0
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :%PORT% ^| findstr LISTENING 2^>nul') do (
    set FOUND=1
    for /f "tokens=1" %%b in ('tasklist /FI "PID eq %%a" /NH 2^>nul ^| findstr /V "INFO:"') do (
        echo [%%a] %%b
    )
    taskkill /PID %%a /F >nul 2>&1
    if !errorlevel!==0 (
        echo ✅ 已结束 PID %%a
    ) else (
        echo ❌ 结束失败 (请尝试管理员身份)
    )
)

if !FOUND!==0 (
    echo 未找到占用端口 %PORT% 的进程
)

pause