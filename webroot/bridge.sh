#!/system/bin/sh
# =============================================================
# XpengSideKey WebUI <-> Shell 桥接 (bridge.sh)
# 由 KernelSU WebUI 通过 ksu.exec 以 root 调用：
#   sh bridge.sh <action> [b64arg...]
# 输出统一为单行 JSON: {"ok":bool,"code":"...","data":"<b64(payload)>"}
# 安全：动作白名单、参数 base64 传输、配置键白名单、值校验
# =============================================================

MODDIR=/data/adb/modules/xpengsidekey
BASE="$MODDIR/xpengsidekey"
. "$BASE/tools.sh"
command -v xsk_run_action >/dev/null 2>&1 || . "$BASE/actions.sh"

b64e() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

respond() { # $1=ok(0/1) $2=code $3=payload
  printf '{"ok":%s,"code":"%s","data":"%s"}\n' "$1" "$2" "$(b64e "$3")"
}

act=$1
shift 2>/dev/null

PRESET_ACTIONS="none ringer_cycle dnd_toggle screenshot wechat_scan wechat_pay alipay_scan alipay_pay camera assistant custom custom_1 custom_2 custom_3 custom_4 custom_5 custom_6"

is_preset_action() {
  case " $PRESET_ACTIONS " in *" $1 "*) return 0 ;; esac
  return 1
}

case "$act" in

  status)
    xsk_load_conf
    ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    drunning=0
    xsk_daemon_running && drunning=1
    ovlex=0; [ -n "$kl_overlay_rel" ] && [ -f "$MODDIR/system/$kl_overlay_rel" ] && ovlex=1
    srcex=0; [ -n "$kl_source" ] && [ -f "$kl_source" ] && srcex=1
    lstate=none
    [ -f "$XSK_RUND/learn.state" ] && lstate=running
    [ -f "$XSK_RUND/learn.result" ] && lstate=done
    logsz=$(wc -c < "$XSK_LOG" 2>/dev/null | tr -d ' \r\n')
    P="version=$ver
device=$(getprop ro.product.device 2>/dev/null)
model=$(getprop ro.product.model 2>/dev/null)
release=$(getprop ro.build.version.release 2>/dev/null)
sdk=$(getprop ro.build.version.sdk 2>/dev/null)
daemon_running=$drunning
meta_active=$(xsk_meta_active && echo 1 || echo 0)
enabled=$enabled
haptic=$haptic
remap_enabled=$remap_enabled
remap_label=$remap_keycode_name
click_gap_ms=$click_gap_ms
long_press_ms=$long_press_ms
bind_single=$bind_single
bind_double=$bind_double
bind_long=$bind_long
custom_single_cmd=$custom_single_cmd
custom_double_cmd=$custom_double_cmd
custom_long_cmd=$custom_long_cmd
custom_1_name=$custom_1_name
custom_1_cmd=$custom_1_cmd
custom_2_name=$custom_2_name
custom_2_cmd=$custom_2_cmd
custom_3_name=$custom_3_name
custom_3_cmd=$custom_3_cmd
custom_4_name=$custom_4_name
custom_4_cmd=$custom_4_cmd
custom_5_name=$custom_5_name
custom_5_cmd=$custom_5_cmd
custom_6_name=$custom_6_name
custom_6_cmd=$custom_6_cmd
key_scancode=$key_scancode
key_device_name=$key_device_name
key_device_node=$key_device_node
kl_source=$kl_source
kl_overlay_rel=$kl_overlay_rel
detection_confident=$detection_confident
kl_overlay_exists=$ovlex
kl_source_exists=$srcex
learn_state=$lstate
log_size=${logsz:-0}
module_dir=$MODDIR"
    respond 1 OK "$P"
    ;;

  set_conf) # 可重复 key value 对（均 b64）
    ok=1
    while [ $# -ge 2 ]; do
      k=$(b64d "$1"); v=$(b64d "$2"); shift 2
      case "$k" in
        enabled|haptic|remap_enabled)
          case "$v" in 0|1) xsk_conf_set "$k" "$v" || ok=0 ;; *) ok=0 ;; esac ;;
        click_gap_ms|long_press_ms)
          if str_only "$v" '0-9' && [ "$v" -ge 100 ] && [ "$v" -le 2000 ]; then xsk_conf_set "$k" "$v" || ok=0; else ok=0; fi ;;
        bind_single|bind_double|bind_long)
          if is_preset_action "$v"; then xsk_conf_set "$k" "$v" || ok=0; else ok=0; fi ;;
        custom_single_cmd|custom_double_cmd|custom_long_cmd)
          [ ${#v} -le 1000 ] && xsk_conf_set "$k" "$v" || ok=0 ;;
        log_max_kb)
          if str_only "$v" '0-9' && [ "$v" -ge 50 ] && [ "$v" -le 4096 ]; then xsk_conf_set "$k" "$v" || ok=0; else ok=0; fi ;;
        *) ok=0 ;;
      esac
    done
    xsk_log WEBUI "set_conf ok=$ok"
    [ "$ok" = "1" ] && respond 1 OK "saved" || respond 0 INVALID "存在未通过校验的配置项"
    ;;

  bind) # $1=trigger $2=action
    t=$(b64d "$1"); a=$(b64d "$2")
    case "$t" in single|double|long) ;; *) respond 0 INVALID "bad trigger"; exit 0 ;; esac
    if is_preset_action "$a"; then
      xsk_conf_set "bind_$t" "$a" && xsk_log WEBUI "bind $t -> $a"
      xsk_daemon_running && xsk_daemon_restart
      respond 1 OK "bind_$t=$a"
    else
      respond 0 INVALID "未知功能: $a"
    fi
    ;;

  set_custom_cmd) # $1=trigger $2=cmd
    t=$(b64d "$1"); c=$(b64d "$2")
    case "$t" in single|double|long) ;; *) respond 0 INVALID "bad trigger"; exit 0 ;; esac
    [ ${#c} -le 1000 ] || { respond 0 INVALID "命令过长(>1000)"; exit 0; }
    xsk_conf_set "custom_${t}_cmd" "$c" || { respond 0 ERR "写入失败"; exit 0; }
    xsk_log WEBUI "custom cmd set for $t"
    xsk_daemon_running && xsk_daemon_restart
    respond 1 OK "saved"
    ;;

  set_remap_label) # $1=label (AKEYCODE 标签)
    l=$(b64d "$1")
    str_only "$l" 'A-Z0-9_' || { respond 0 INVALID "标签需为大写A-Z/0-9/下划线"; exit 0; }
    [ ${#l} -le 24 ] || { respond 0 INVALID "标签过长"; exit 0; }
    xsk_conf_set remap_keycode_name "$l" || { respond 0 ERR "写入失败"; exit 0; }
    xsk_gen_kl_overlay
    xsk_log WEBUI "remap label -> $l"
    respond 1 OK "已生成 overlay，重启手机后生效"
    ;;

  save_key) # $1=scancode [$2=node] [$3=name]
    sc=$(b64d "$1")
    str_only "$sc" '0-9' || { respond 0 INVALID "键值必须为十进制数字"; exit 0; }
    [ "$sc" -ge 1 ] && [ "$sc" -le 767 ] || { respond 0 INVALID "键值范围 1-767"; exit 0; }
    xsk_conf_set key_scancode "$sc" || { respond 0 ERR "写入失败"; exit 0; }
    if [ $# -ge 2 ]; then
      nd=$(b64d "$2")
      case "$nd" in
        /dev/input/event[0-9]*|'') xsk_conf_set key_device_node "$nd" ;;
        *) respond 0 INVALID "非法节点路径"; exit 0 ;;
      esac
    fi
    if [ $# -ge 3 ]; then
      nm=$(b64d "$3")
      if str_only "$nm" 'A-Za-z0-9 _-' && [ ${#nm} -le 48 ]; then
        xsk_conf_set key_device_name "$nm"
      else
        respond 0 INVALID "非法设备名"; exit 0
      fi
    fi
    xsk_conf_set detection_confident 1
    xsk_gen_kl_overlay
    xsk_daemon_running && xsk_daemon_restart
    xsk_log WEBUI "key saved: sc=$sc"
    respond 1 OK "键值已保存($sc)；键位映射需重启手机生效"
    ;;

  learn_start)
    rm -f "$XSK_RUND/learn.result" "$XSK_RUND/learn.request" 2>/dev/null
    if xsk_daemon_running; then
      # 主通道：守护进程在已验证可用的 getevent 通道上捕获下一次按键
      : > "$XSK_RUND/learn.request"
      xsk_log WEBUI "learn_start via daemon"
      respond 1 OK "started-daemon"
    else
      # 兜底：守护未运行时用后台 getevent 捕获
      xsk_learn_start 12 && respond 1 OK "started" || respond 1 OK "busy"
    fi
    ;;
  learn_result)
    if [ -f "$XSK_RUND/learn.result" ]; then
      respond 1 OK "$(cat "$XSK_RUND/learn.result" 2>/dev/null)"
    elif [ -f "$XSK_RUND/learn.request" ] || [ -f "$XSK_RUND/learn.state" ]; then
      respond 1 OK "running"
    else
      respond 1 OK "none"
    fi
    ;;
  learn_cancel)
    rm -f "$XSK_RUND/learn.request" "$XSK_RUND/learn.state" "$XSK_RUND/learn.result" 2>/dev/null
    respond 1 OK "cancelled"
    ;;

  apply_kl)
    xsk_gen_kl_overlay
    xsk_load_conf
    if [ -f "$MODDIR/system/$kl_overlay_rel" ]; then
      xsk_log WEBUI "apply_kl ok"
      respond 1 OK "overlay 已生成: $kl_overlay_rel\n修改键位映射后需重启手机生效"
    else
      respond 1 OK "未生成 overlay（remap 关闭或缺少源 kl）"
    fi
    ;;

  test_action) # $1=action [$2=cmd]
    a=$(b64d "$1"); c=$(b64d "$2")
    is_preset_action "$a" || { respond 0 INVALID "未知功能: $a"; exit 0; }
    xsk_run_action "$a" "$c" >/dev/null 2>&1
    rc=$?
    out=$(tail -n 14 "$XSK_LOG" 2>/dev/null)
    xsk_log WEBUI "test_action $a rc=$rc"
    respond 1 OK "rc=$rc
$out"
    ;;

  daemon) # $1=start|stop|restart
    op=$(b64d "$1")
    case "$op" in
      start)   xsk_conf_set enabled 1; xsk_daemon_start; xsk_watchdog_start ;;
      stop)    xsk_conf_set enabled 0; xsk_daemon_stop ;;
      restart) xsk_conf_set enabled 1; xsk_daemon_start; xsk_watchdog_start ;;
      *) respond 0 INVALID "bad op"; exit 0 ;;
    esac
    xsk_daemon_running && st=running || st=stopped
    respond 1 OK "daemon $st"
    ;;

  log) # $1=bytes
    n=$(b64d "$1")
    str_only "$n" '0-9' || n=12000
    [ "$n" -le 65536 ] || n=65536
    respond 1 OK "$(tail -c "$n" "$XSK_LOG" 2>/dev/null)"
    ;;
  clear_log)
    : > "$XSK_LOG" 2>/dev/null
    xsk_log WEBUI "log cleared"
    respond 1 OK "log cleared"
    ;;

  export_conf)
    respond 1 OK "$(cat "$XSK_CONF" 2>/dev/null)"
    ;;
  import_conf) # $1=b64(config text)
    txt=$(b64d "$1")
    n=0; bad=0
    printf '%s\n' "$txt" | while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      [ "$k" = "$line" ] && continue
      case "$k" in
        enabled|haptic|remap_enabled)
          case "$v" in 0|1) xsk_conf_set "$k" "$v" ;; esac ;;
        click_gap_ms|long_press_ms)
          if str_only "$v" '0-9' && [ "$v" -ge 100 ] && [ "$v" -le 2000 ]; then xsk_conf_set "$k" "$v"; fi ;;
        bind_single|bind_double|bind_long)
          is_preset_action "$v" && xsk_conf_set "$k" "$v" ;;
        remap_keycode_name)
          if str_only "$v" 'A-Z0-9_' && [ ${#v} -le 24 ]; then xsk_conf_set "$k" "$v"; fi ;;
        custom_single_cmd|custom_double_cmd|custom_long_cmd)
          [ ${#v} -le 1000 ] && xsk_conf_set "$k" "$v" ;;
        custom_[1-6]_name)
          [ ${#v} -le 24 ] && xsk_conf_set "$k" "$v" ;;
        custom_[1-6]_cmd)
          [ ${#v} -le 1000 ] && xsk_conf_set "$k" "$v" ;;
        log_max_kb)
          if str_only "$v" '0-9' && [ "$v" -ge 50 ] && [ "$v" -le 4096 ]; then xsk_conf_set "$k" "$v"; fi ;;
        *) ;;
      esac
    done
    xsk_log WEBUI "config imported"
    xsk_daemon_running && xsk_daemon_restart
    respond 1 OK "配置已导入并应用（键位映射重启后生效）"
    ;;
  reset_conf)
    xsk_conf_set enabled 1
    xsk_conf_set haptic 1
    xsk_conf_set remap_enabled 1
    xsk_conf_set remap_keycode_name UNKNOWN
    xsk_conf_set click_gap_ms 300
    xsk_conf_set long_press_ms 550
    xsk_conf_set bind_single wechat_scan
    xsk_conf_set bind_double wechat_pay
    xsk_conf_set bind_long ringer_cycle
    xsk_conf_set custom_single_cmd ""
    xsk_conf_set custom_double_cmd ""
    xsk_conf_set custom_long_cmd ""
    xsk_daemon_running && xsk_daemon_start
    xsk_gen_kl_overlay
    xsk_log WEBUI "config reset to defaults"
    respond 1 OK "已恢复默认设置（自定义功能槽位与按键识别保留）"
    ;;

  add_custom) # $1=name $2=cmd
    nm=$(b64d "$1"); cm=$(b64d "$2")
    [ -n "$nm" ] && [ ${#nm} -le 24 ] || { respond 0 INVALID "名称需 1-24 字符"; exit 0; }
    [ ${#cm} -le 1000 ] || { respond 0 INVALID "命令过长"; exit 0; }
    n=""
    for i in 1 2 3 4 5 6; do
      if [ -z "$(xsk_conf_get "custom_${i}_name")" ] && [ -z "$(xsk_conf_get "custom_${i}_cmd")" ]; then
        n=$i; break
      fi
    done
    [ -n "$n" ] || { respond 0 FULL "自定义功能已满(6个)，请先删除"; exit 0; }
    xsk_conf_set "custom_${n}_name" "$nm" && xsk_conf_set "custom_${n}_cmd" "$cm" ||
      { respond 0 ERR "写入失败"; exit 0; }
    xsk_daemon_running && xsk_daemon_restart
    xsk_log WEBUI "custom_$n added: $nm"
    respond 1 OK "custom_$n"
    ;;
  save_custom) # $1=n $2=name $3=cmd
    n=$(b64d "$1"); nm=$(b64d "$2"); cm=$(b64d "$3")
    case "$n" in [1-6]) ;; *) respond 0 INVALID "bad slot"; exit 0 ;; esac
    str_only "$nm" 'A-Za-z0-9 _-' || { respond 0 INVALID "名称仅支持字母/数字/空格/下划线/中划线"; exit 0; }
    [ ${#nm} -le 24 ] || { respond 0 INVALID "名称过长"; exit 0; }
    [ ${#cm} -le 1000 ] || { respond 0 INVALID "命令过长"; exit 0; }
    xsk_conf_set "custom_${n}_name" "$nm" && xsk_conf_set "custom_${n}_cmd" "$cm" ||
      { respond 0 ERR "写入失败"; exit 0; }
    xsk_daemon_running && xsk_daemon_restart
    xsk_log WEBUI "custom_$n saved: $nm"
    respond 1 OK "saved"
    ;;
  del_custom) # $1=n
    n=$(b64d "$1")
    case "$n" in [1-6]) ;; *) respond 0 INVALID "bad slot"; exit 0 ;; esac
    xsk_conf_set "custom_${n}_name" ""
    xsk_conf_set "custom_${n}_cmd" ""
    xsk_daemon_running && xsk_daemon_restart
    xsk_log WEBUI "custom_$n deleted"
    respond 1 OK "deleted"
    ;;

  diagnose)
    respond 1 OK "$(xsk_diagnose 2>&1 | head -c 24000)"
    ;;

  *)
    respond 0 UNKNOWN "未知动作: $act"
    ;;
esac

exit 0
