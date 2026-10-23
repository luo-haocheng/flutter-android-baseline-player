@echo off
chcp 65001 >nul
REM 在模拟器上运行 Flutter 应用（等价于 scripts\run-emulator.ps1，
REM 但走 -ExecutionPolicy Bypass，不会被系统的脚本签名策略拦住）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-emulator.ps1"
pause
