#!/system/bin/sh
# =============================================================
# XpengSideKey 按键守护进程 (daemon.sh)
# getevent 后台采集 + 轮询解析（避免管道子 shell 状态丢失）
# 状态全部落盘于模块私有 run/ 目录，单击/双击/长按判定：
#   按下 -> 计时 long_press_ms 未松开 => 长按（立即触发）
#   松开 -> 等待 click_gap_ms 无再次按下 => 单击 / 双击
# Android 16 适配：root(su) 域进程 + oom_score_adj(-1000)，
# 不受前台服务/后台启动限制；模块禁用时自动退出。
# =============================================================

MODDIR=/data/adb/modules/xpengsidekey
BASE="$MODDIR/xpengsidekey"
. "$BASE/tools.sh"
command -v xsk_run_action >/dev/null 2>&1 || . "$BASE/actions.sh"

xsk_boot_init
xsk_load_conf
[ "$enabled" = "1" ] || { xsk_log DAEMON "config disabled, daemon not started"; exit 0; }
[ -f "$MODDIR/disable" ] && { xsk_log DAEMON "module disabled, daemon not started"; exit 0; }

echo $$ > "$XSK_RUND/daemon.pid" 2>/dev/null
[ -w "/proc/$$/oom_score_adj" ] && echo -1000 > "/proc/$$/oom_score_adj" 2>/dev/null

# ---------- 运行态文件 ----------
down_ts_f="$XSK_RUND/ev.down_ts"
up_ts_f="$XSK_RUND/ev.up_ts"
useq_f="$XSK_RUND/ev.useq"
clicks_f="$XSK_RUND/ev.clicks"
sup_f="$XSK_RUND/ev.suppress"

reset_cycle() {
  echo 0 > "$clicks_f" 2>/dev/null
  echo 0 > "$sup_f" 2>/dev/null
  echo 0 > "$useq_f" 2>/dev/null
  rm -f "$down_ts_f" "$up_ts_f" 2>/dev/null
}
reset_cycle

cleanup() {
  xsk_log DAEMON "daemon exit (signal)"
  [ -n "$gev" ] && kill "$gev" 2>/dev/null
  rm -f "$XSK_RUND/daemon.pid" "$XSK_RUND/getevent.pid" 2>/dev/null
  exit 0
}
trap cleanup TERM INT

# ---------- 动作分发 ----------
fire() { # $1=single|double|long
  case "$1" in
    single) a=$bind_single; c=$custom_single_cmd ;;
    double) a=$bind_double; c=$custom_double_cmd ;;
    long)   a=$bind_long;   c=$custom_long_cmd ;;
  esac
  xsk_log INPUT "trigger: $1 -> $a"
  (
    xsk_run_action "$a" "$c" >/dev/null 2>&1
  ) &
}

# ---------- 状态机 ----------
handle_down() {
  echo 0 > "$sup_f"
  ts=$(xsk_now_ms)
  echo "$ts" > "$down_ts_f"
  rm -f "$up_ts_f" 2>/dev/null
  (
    sleep "$(ms2s "$long_press_ms")"
    [ "$(cat "$down_ts_f" 2>/dev/null)" = "$ts" ] || exit 0
    [ -f "$up_ts_f" ] && exit 0
    [ "$(cat "$sup_f" 2>/dev/null)" = "1" ] && exit 0
    echo 1 > "$sup_f"
    fire long
  ) &
}

handle_up() {
  ts=$(xsk_now_ms)
  echo "$ts" > "$up_ts_f"
  # 每次松开发放单调递增序号，供判定器识别自己是否已被更新的松开事件取代
  uq=$(cat "$useq_f" 2>/dev/null); uq=$(( ${uq:-0} + 1 )); echo "$uq" > "$useq_f"
  c=$(cat "$clicks_f" 2>/dev/null); c=$(( ${c:-0} + 1 )); echo "$c" > "$clicks_f"
  (
    sleep "$(ms2s "$click_gap_ms")"
    # 已有更新的松开事件 → 本次判定让位（修复双击触发两次的关键守卫）
    [ "$(cat "$useq_f" 2>/dev/null)" = "$uq" ] || exit 0
    # 仍在按住（有更新的按下）→ 不判定
    d=$(cat "$down_ts_f" 2>/dev/null); u=$(cat "$up_ts_f" 2>/dev/null)
    [ -n "$d" ] && [ -n "$u" ] && [ "$d" -gt "$u" ] 2>/dev/null && exit 0
    if [ "$(cat "$sup_f" 2>/dev/null)" = "1" ]; then
      echo 0 > "$clicks_f"; exit 0
    fi
    c=$(cat "$clicks_f" 2>/dev/null)
    echo 0 > "$clicks_f"
    case "$c" in
      1) fire single ;;
      *) fire double ;;
    esac
  ) &
}

handle_line() {
  set -- $1
  [ $# -ge 3 ] || return 0
  [ $# -ge 4 ] && shift
  t=$1; c=$2; v=$3
  [ "$t" = "0001" ] || return 0
  dec=$((0x$c)) 2>/dev/null || return 0
  # 学习模式：由守护进程代为捕获下一次按键（复用已验证可用的 getevent 通道），
  # 写入 learn.result 并抑制本次触发动作
  if [ "$v" = "00000001" ] && [ -f "$XSK_RUND/learn.request" ]; then
    printf '%s %s\n' "$dec" "$node" > "$XSK_RUND/learn.result" 2>/dev/null
    rm -f "$XSK_RUND/learn.request" 2>/dev/null
    echo 1 > "$sup_f" 2>/dev/null
    xsk_log LEARN "captured scancode=$dec node=$node"
    return 0
  fi
  [ "$dec" = "$key_scancode" ] || return 0
  case "$v" in
    00000001) handle_down ;;
    00000000) handle_up ;;
  esac
}

kill_gev() {
  gp=$(cat "$XSK_RUND/getevent.pid" 2>/dev/null | tr -d ' \r\n')
  [ -n "$gp" ] && kill "$gp" 2>/dev/null
  return 0
}

# ---------- 主循环 ----------
while :; do
  [ -f "$MODDIR/disable" ] && { xsk_log DAEMON "module disabled, exit"; cleanup; }
  xsk_load_conf
  [ "$enabled" = "1" ] || { xsk_log DAEMON "config disabled, exit"; cleanup; }

  if [ -z "$key_scancode" ]; then
    xsk_log DAEMON "key_scancode empty, waiting for WebUI learn"
    sleep 15
    continue
  fi

  # 节点解析：设备名优先（event 编号可能随开机顺序变化），存储节点兜底
  node=""
  if [ -n "$key_device_name" ]; then
    node=$(xsk_node_by_name "$key_device_name" 2>/dev/null)
  fi
  if [ -z "$node" ] && [ -n "$key_device_node" ] && [ -e "$key_device_node" ]; then
    node=$key_device_node
  fi
  if [ -z "$node" ]; then
    xsk_log DAEMON "input device not found ($key_device_name), retry in 5s"
    sleep 5
    continue
  fi

  raw="$XSK_RUND/raw.log"
  : > "$raw" 2>/dev/null
  getevent "$node" 2>/dev/null >> "$raw" &
  gev=$!
  echo "$gev" > "$XSK_RUND/getevent.pid" 2>/dev/null
  xsk_log DAEMON "watching $node (scancode=$key_scancode)"
  off=0
  beat=0
  echo "$(xsk_now_ms)" > "$XSK_RUND/daemon.beat" 2>/dev/null

  while [ -d "/proc/$gev" ]; do
    [ -f "$MODDIR/disable" ] && break
    size=$(wc -c < "$raw" 2>/dev/null | tr -d ' \r\n')
    [ -n "$size" ] || size=0
    if [ "$size" -gt "$off" ]; then
      data=$(tail -c +$((off + 1)) "$raw" 2>/dev/null)
      rest=$data
      consumed=0
      while :; do
        case "$rest" in
          *"
"*)
            line=${rest%%"
"*}
            rest=${rest#*"
"}
            consumed=$((consumed + ${#line} + 1))
            [ -n "$line" ] && handle_line "$line"
            ;;
          *) break ;;
        esac
      done
      off=$((off + consumed))
      if [ "$size" -gt 65536 ]; then
        : > "$raw" 2>/dev/null
        off=0
      fi
    fi
    sleep 0.06
    # 心跳：约每 4 秒刷新一次，供看门狗检测僵死
    beat=$((beat + 1))
    if [ "$beat" -ge 64 ]; then
      beat=0
      echo "$(xsk_now_ms)" > "$XSK_RUND/daemon.beat" 2>/dev/null
    fi
  done

  kill "$gev" 2>/dev/null
  xsk_log DAEMON "getevent exited (node=$node), re-resolving"
  sleep 1
done
