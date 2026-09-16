@echo off
chcp 65001 >nul
title TeleAgent 蜡笔小新主题卸载器
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-theme.ps1" -Restart
echo.
if errorlevel 1 (
  echo 卸载没有完成，请保留备份并把上面的错误信息交给 TeleAgent 或 Codex 检查。
) else (
  echo 原始界面已经恢复，可以关闭此窗口。
)
pause
