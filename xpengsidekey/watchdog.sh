#!/system/bin/sh
# =============================================================
# XpengSideKey 守护进程看门狗 (watchdog.sh)
# 每 30 秒检查一次：
#   - 守护进程死亡 → 立即拉起
#   - 心跳超过 90 秒未更新（僵死）→ 重启（带 8 秒复查，避免深睡恢复误判）
# 用户主动停止（enabled=0 或模块禁用）时自动退出
# =============================================================

MODDIR=/data/adb/modules/xpengsidekey
BASE="$MODDIR/xpengsidekey"
. "$BASE/tools.sh"

echo $$ > "$XSK_RUND/watchdog.pid" 2>/dev/null
[ -w "/proc/$$/oom_score_adj" ] && echo -1000 > "/proc/$$/oom_score_adj" 2>/dev/null
xsk_log WATCHDOG "watchdog up (pid $$)"

while :; do
  sleep 30
  if [ -f "$MODDIR/disable" ]; then
    xsk_log WATCHDOG "module disabled, exit"
    rm -f "$XSK_RUND/watchdog.pid" 2>/dev/null
    exit 0
  fi
  xsk_load_conf
  if [ "$enabled" != "1" ]; then
    xsk_log WATCHDOG "config disabled, exit"
    rm -f "$XSK_RUND/watchdog.pid" 2>/dev/null
    exit 0
  fi
  if ! xsk_daemon_running; then
    xsk_log WATCHDOG "daemon dead, restarting"
    xsk_daemon_start
    continue
  fi
  beat=$(cat "$XSK_RUND/daemon.beat" 2>/dev/null | tr -d ' \r\n')
  now=$(xsk_now_ms)
  [ -n "$beat" ] && [ -n "$now" ] || continue
  age=$((now - beat))
  [ "$age" -gt 90000 ] || continue
  # 深睡恢复时心跳会短暂滞后，等待 8 秒复查避免误杀健康进程
  sleep 8
  beat=$(cat "$XSK_RUND/daemon.beat" 2>/dev/null | tr -d ' \r\n')
  now=$(xsk_now_ms)
  age=$((now - beat))
  if [ "$age" -gt 90000 ]; then
    xsk_log WATCHDOG "heartbeat stale ${age}ms, restarting daemon"
    xsk_daemon_start
  fi
done
