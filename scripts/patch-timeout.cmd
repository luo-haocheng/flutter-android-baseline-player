@echo off
chcp 65001 >nul
echo ============================================
echo  修复 Flutter 插件 5 秒超时（5000ms -^> 30000ms）
echo  请先完全退出 Android Studio！
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-flutter-plugin-timeout.ps1"
echo.
pause
