#!/system/bin/sh
# XpengSideKey 卸载脚本
# 核心复原由 KernelSU 自动完成：模块目录(含 overlay 与配置)随卸载整体移除。
# 此处仅停止守护进程，不做任何系统文件操作。
MODDIR=/data/adb/modules/xpengsidekey
PIDF="$MODDIR/xpengsidekey/run/daemon.pid"
GEVF="$MODDIR/xpengsidekey/run/getevent.pid"
WPIDF="$MODDIR/xpengsidekey/run/watchdog.pid"
[ -f "$PIDF" ] && kill "$(cat "$PIDF" 2>/dev/null | tr -d ' \r\n')" 2>/dev/null
[ -f "$GEVF" ] && kill "$(cat "$GEVF" 2>/dev/null | tr -d ' \r\n')" 2>/dev/null
[ -f "$WPIDF" ] && kill "$(cat "$WPIDF" 2>/dev/null | tr -d ' \r\n')" 2>/dev/null
pkill -f "xpengsidekey/daemon.sh" 2>/dev/null
pkill -f "xpengsidekey/watchdog.sh" 2>/dev/null
exit 0
