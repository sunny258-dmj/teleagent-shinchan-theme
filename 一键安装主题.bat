@echo off
chcp 65001 >nul
title TeleAgent 蜡笔小新主题安装器
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-theme.ps1" -Restart
echo.
if errorlevel 1 (
  echo 安装没有完成，请把上面的错误信息交给 TeleAgent 或 Codex 检查。
) else (
  echo 安装完成，可以关闭此窗口。
)
pause
