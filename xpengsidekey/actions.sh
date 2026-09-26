#!/system/bin/sh
# =============================================================
# XpengSideKey 动作执行库 (actions.sh)
# 依赖 tools.sh（需先 source）
# 所有候选命令均带多版本回退链，输出与错误写入模块日志
# =============================================================

command -v xsk_log >/dev/null 2>&1 || . /data/adb/modules/xpengsidekey/xpengsidekey/tools.sh

# ---------- 通用：逐条尝试 am 命令 ----------
# 判定成功：输出含 "Starting:" 且无 "Error type"/"Error:"
xsk_try_am() {
  for c in "$@"; do
    xsk_log ACTION "try: $c"
    out=$(sh -c "$c" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -q "Starting:" &&
       ! printf '%s' "$out" | grep -qi "Error type\|Error:\|SecurityException\|Exception"; then
      xsk_log ACTION "ok: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      return 0
    fi
    xsk_log ACTION "fail($rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  done
  return 1
}

# ---------- 振动反馈 ----------
xsk_haptic() {
  [ "${haptic:-$(xsk_conf_get haptic)}" = "1" ] || return 0
  cmd vibrator_manager oneshot 60 >/dev/null 2>&1 ||
    cmd vibrator_manager synced oneshot 60 >/dev/null 2>&1 ||
    cmd vibrator timed 60 >/dev/null 2>&1 || return 0
}

# ---------- 响铃/振动/静音 ----------
xsk_get_ringer() {
  m=$(cmd audio get-ringer-mode 2>/dev/null | tr -d ' \r\n')
  case "$m" in
    NORMAL|VIBRATE|SILENT) echo "$m"; return 0 ;;
  esac
  m=$(settings get global mode_ringer 2>/dev/null | tr -d ' \r\n')
  case "$m" in
    0) echo SILENT ;;
    1) echo VIBRATE ;;
    2) echo NORMAL ;;
    *) echo "" ;;
  esac
}

xsk_set_ringer() { # $1=NORMAL|VIBRATE|SILENT
  m=$1
  case "$m" in NORMAL|VIBRATE|SILENT) ;; *) return 1 ;; esac
  cmd audio set-ringer-mode "$m" >/dev/null 2>&1 && return 0
  cmd audio set_ringer_mode "$m" >/dev/null 2>&1 && return 0
  case "$m" in NORMAL) n=2 ;; VIBRATE) n=1 ;; SILENT) n=0 ;; esac
  settings put global mode_ringer "$n" >/dev/null 2>&1
}

xsk_act_ringer() {
  cur=$(xsk_get_ringer)
  case "$cur" in
    VIBRATE) nxt=SILENT ;;
    SILENT)  nxt=NORMAL ;;
    *)       nxt=VIBRATE ;;
  esac
  if xsk_set_ringer "$nxt"; then
    xsk_log ACTION "ringer: ${cur:-unknown} -> $nxt"
  else
    xsk_log ACTION "ringer: set failed"
    return 1
  fi
}

# ---------- 免打扰 ----------
xsk_act_dnd() {
  zen=$(settings get global zen_mode 2>/dev/null | tr -d ' \r\n ')
  if [ "$zen" != "0" ] && [ "$zen" != "null" ] && [ -n "$zen" ]; then
    cmd notification set_dnd off >/dev/null 2>&1 ||
      settings put global zen_mode 0 >/dev/null 2>&1
    xsk_log ACTION "dnd -> off"
  else
    cmd notification set_dnd priority >/dev/null 2>&1 ||
      cmd notification set_dnd on >/dev/null 2>&1 ||
      settings put global zen_mode 1 >/dev/null 2>&1
    xsk_log ACTION "dnd -> on(priority)"
  fi
}

# ---------- 截屏 ----------
xsk_act_screenshot() {
  if input keyevent 120 >/dev/null 2>&1; then
    xsk_log ACTION "screenshot via keyevent 120"
    return 0
  fi
  d=/sdcard/Pictures/Screenshots
  mkdir -p "$d" 2>/dev/null
  f="$d/XSK_$(date +%Y%m%d_%H%M%S).png"
  screencap -p "$f" 2>/dev/null
  xsk_log ACTION "screenshot via screencap: $f"
}

# ---------- 预设动作 ----------
xsk_act_wechat_scan() {
  xsk_try_am \
    'am start -n com.tencent.mm/.plugin.scanner.ui.BaseScanUI' \
    'am start -n com.tencent.mm/com.tencent.mm.plugin.scanner.ui.BaseScanUI' \
    'am start -a android.intent.action.VIEW -d "weixin://dl/scan"' \
    'am start -a android.intent.action.MAIN -p com.tencent.mm'
}

xsk_act_wechat_pay() {
  xsk_try_am \
    'am start -n com.tencent.mm/com.tencent.mm.plugin.offline.ui.WalletOfflineCoinPurseUI' \
    'am start -n com.tencent.mm/.plugin.offline.ui.WalletOfflineCoinPurseUI' \
    'am start -a android.intent.action.VIEW -d "weixin://dl/wallet"' \
    'am start -a android.intent.action.MAIN -p com.tencent.mm'
}

xsk_act_alipay_scan() {
  xsk_try_am \
    'am start -a android.intent.action.VIEW -d "alipays://platformapi/startapp?appId=10000007"' \
    'am start -a android.intent.action.VIEW -d "alipayqr://platformapi/startapp?appId=10000007"' \
    'am start -n com.eg.android.AlipayGphone/.AlipayLogin' \
    'am start -a android.intent.action.MAIN -p com.eg.android.AlipayGphone'
}

xsk_act_alipay_pay() {
  xsk_try_am \
    'am start -a android.intent.action.VIEW -d "alipays://platformapi/startapp?appId=20000056"' \
    'am start -a android.intent.action.VIEW -d "alipayqr://platformapi/startapp?appId=20000056"' \
    'am start -n com.eg.android.AlipayGphone/.AlipayLogin' \
    'am start -a android.intent.action.MAIN -p com.eg.android.AlipayGphone'
}

xsk_act_camera() {
  xsk_try_am \
    'am start -a android.media.action.STILL_IMAGE_CAMERA' \
    'am start -a android.intent.action.MAIN -c android.intent.category.APP_CAMERA'
}

xsk_act_assistant() {
  if xsk_try_am \
    'am start -a android.intent.action.VOICE_COMMAND' \
    'am start -a android.intent.action.VOICE_ASSIST' \
    'am start -a android.intent.action.ASSIST'; then
    return 0
  fi
  input keyevent 219 >/dev/null 2>&1
}

# ---------- 总入口 ----------
xsk_run_action() { # $1=action id  $2=custom 命令(仅 action=custom 时)
  act=$1; cmdv=$2
  xsk_log ACTION "run: $act"
  xsk_haptic
  rc=0; out=""
  case "$act" in
    ringer_cycle) xsk_act_ringer ;;
    dnd_toggle)   xsk_act_dnd ;;
    screenshot)   xsk_act_screenshot ;;
    wechat_scan)  xsk_act_wechat_scan || rc=1 ;;
    wechat_pay)   xsk_act_wechat_pay || rc=1 ;;
    alipay_scan)  xsk_act_alipay_scan || rc=1 ;;
    alipay_pay)   xsk_act_alipay_pay || rc=1 ;;
    camera)       xsk_act_camera || rc=1 ;;
    assistant)    xsk_act_assistant || rc=1 ;;
    none)         ;;
    custom)
      if [ -n "$cmdv" ]; then
        out=$(sh -c "$cmdv" 2>&1); rc=$?
      else
        rc=1; out="custom command is empty"
      fi
      ;;
    custom_[1-6])
      n=${act#custom_}
      c=$(xsk_conf_get "custom_${n}_cmd")
      if [ -n "$c" ]; then
        out=$(sh -c "$c" 2>&1); rc=$?
      else
        rc=1; out="custom_${n}_cmd is empty"
      fi
      ;;
    *) rc=1; out="unknown action: $act" ;;
  esac
  [ -n "$out" ] && xsk_log ACTION "result($rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  return $rc
}
