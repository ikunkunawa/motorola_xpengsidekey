#!/system/bin/sh
# XpengSideKey service: late_start 阶段启动守护进程
# root(su) 域进程不受 Android 16 ActivityManager 后台限制；
# 守护进程自身将 oom_score_adj 置 -1000，避免被 lmkd/幻象进程查杀。
MODDIR=/data/adb/modules/xpengsidekey
BASE="$MODDIR/xpengsidekey"
[ -f "$BASE/tools.sh" ] || exit 0
. "$BASE/tools.sh"
xsk_boot_init
xsk_load_conf
if [ "$enabled" = "1" ] && [ ! -f "$MODDIR/disable" ]; then
  xsk_daemon_start
  xsk_watchdog_start
fi
exit 0
