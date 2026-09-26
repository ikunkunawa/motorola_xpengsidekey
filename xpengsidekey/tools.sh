#!/system/bin/sh
# =============================================================
# XpengSideKey 共享函数库 (tools.sh)
# 供 customize.sh / post-fs-data.sh / service.sh / daemon.sh / bridge.sh 复用
# 仅写入模块私有目录，绝不触碰系统分区
#
# 已验证机型数据 (Motorola Edge S30 / xpeng / Android 16):
#   侧键设备: gpio-keys (通常 /dev/input/event2)
#   侧键 scancode: 217 (KEY_SEARCH)，同设备另有 KEY_VOLUMEUP(115)
#   实际生效 keylayout: /system/usr/keylayout/Generic.kl (无设备专属 kl)
# =============================================================

XSK_MODDIR="${XSK_MODDIR:-/data/adb/modules/xpengsidekey}"
XSK_BASE="$XSK_MODDIR/xpengsidekey"
XSK_CONF="$XSK_BASE/config.prop"
XSK_LOGD="$XSK_BASE/logs"
XSK_RUND="$XSK_BASE/run"
XSK_LOG="$XSK_LOGD/xsk.log"

# ---------------- 时间 ----------------
xsk_now_ms() {
  awk '{printf "%d", $1*1000}' /proc/uptime 2>/dev/null
}

ms2s() { # 毫秒 -> sleep 可用的小数秒
  awk -v m="$1" 'BEGIN{printf "%.2f", m/1000}'
}

# ---------------- 日志（带大小轮转） ----------------
xsk_log() { # $1=TAG $2=message
  mkdir -p "$XSK_LOGD" 2>/dev/null
  printf '%s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" "$2" >> "$XSK_LOG" 2>/dev/null
  max_kb=${XSK_LOG_MAX_KB:-256}
  sz=$(wc -c < "$XSK_LOG" 2>/dev/null | tr -d ' \r\n')
  [ -n "$sz" ] || return 0
  if [ "$sz" -gt $((max_kb * 1024)) ]; then
    tail -c $((max_kb * 512)) "$XSK_LOG" > "$XSK_LOG/.rot" 2>/dev/null &&
      mv -f "$XSK_LOG/.rot" "$XSK_LOG" 2>/dev/null
  fi
  return 0
}

xsk_boot_init() {
  mkdir -p "$XSK_LOGD" "$XSK_RUND" 2>/dev/null
  rm -f "$XSK_RUND"/*.tmp "$XSK_RUND/learn.state" "$XSK_RUND/learn.request" 2>/dev/null
  return 0
}

# ---------------- 字符集校验 ----------------
# str_only <字符串> <允许字符集(tr语法)> : 非空且仅含允许字符时返回 0
# 用 tr 而非 case [!...] 模式：mksh 对括号内空格/连字符的解析有兼容性问题
str_only() {
  [ -n "$1" ] || return 1
  [ -z "$(printf '%s' "$1" | tr -d "$2")" ]
}

# ---------------- 配置 ----------------
xsk_conf_get() { # $1=key -> stdout=value
  sed -n "s/^$1=//p" "$XSK_CONF" 2>/dev/null | head -n 1
}

xsk_conf_set() { # $1=key $2=value（键名白名单校验，值禁止换行）
  k=$1; v=$2
  str_only "$k" 'a-z0-9_' || return 1
  case "$v" in *'
'*) return 1 ;; esac
  [ -f "$XSK_CONF" ] || { mkdir -p "$XSK_BASE" 2>/dev/null; : > "$XSK_CONF" 2>/dev/null; }
  tmp="$XSK_CONF.new"
  found=0
  while IFS= read -r line; do
    lk=${line%%=*}
    if [ "$lk" = "$k" ] && [ "$line" != "$lk" ]; then
      printf '%s=%s\n' "$k" "$v"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done < "$XSK_CONF" > "$tmp" 2>/dev/null
  [ "$found" = "1" ] || printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv -f "$tmp" "$XSK_CONF" 2>/dev/null || return 1
  return 0
}

xsk_load_conf() { # 显式白名单载入，禁用 eval，避免注入
  enabled=1; haptic=1
  key_device_name=gpio-keys; key_device_node=""; key_scancode=217
  key_vid=""; key_pid=""
  remap_enabled=1; remap_keycode=0; remap_keycode_name=UNKNOWN
  kl_source=/system/usr/keylayout/Generic.kl
  kl_overlay_rel=system/usr/keylayout/gpio-keys.kl
  detection_confident=1
  click_gap_ms=300; long_press_ms=550
  bind_single=wechat_scan; bind_double=wechat_pay; bind_long=ringer_cycle
  custom_single_cmd=""; custom_double_cmd=""; custom_long_cmd=""
  custom_1_name=""; custom_1_cmd=""
  custom_2_name=""; custom_2_cmd=""
  custom_3_name=""; custom_3_cmd=""
  custom_4_name=""; custom_4_cmd=""
  custom_5_name=""; custom_5_cmd=""
  custom_6_name=""; custom_6_cmd=""
  log_max_kb=256
  [ -f "$XSK_CONF" ] || return 0
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    [ "$k" = "$line" ] && continue
    case "$k" in
      enabled) enabled=$v ;;
      haptic) haptic=$v ;;
      key_device_name) key_device_name=$v ;;
      key_device_node) key_device_node=$v ;;
      key_scancode) key_scancode=$v ;;
      key_vid) key_vid=$v ;;
      key_pid) key_pid=$v ;;
      remap_enabled) remap_enabled=$v ;;
      remap_keycode) remap_keycode=$v ;;
      remap_keycode_name) remap_keycode_name=$v ;;
      kl_source) kl_source=$v ;;
      kl_overlay_rel) kl_overlay_rel=$v ;;
      detection_confident) detection_confident=$v ;;
      click_gap_ms) click_gap_ms=$v ;;
      long_press_ms) long_press_ms=$v ;;
      bind_single) bind_single=$v ;;
      bind_double) bind_double=$v ;;
      bind_long) bind_long=$v ;;
      custom_single_cmd) custom_single_cmd=$v ;;
      custom_double_cmd) custom_double_cmd=$v ;;
      custom_long_cmd) custom_long_cmd=$v ;;
      custom_1_name) custom_1_name=$v ;;
      custom_1_cmd) custom_1_cmd=$v ;;
      custom_2_name) custom_2_name=$v ;;
      custom_2_cmd) custom_2_cmd=$v ;;
      custom_3_name) custom_3_name=$v ;;
      custom_3_cmd) custom_3_cmd=$v ;;
      custom_4_name) custom_4_name=$v ;;
      custom_4_cmd) custom_4_cmd=$v ;;
      custom_5_name) custom_5_name=$v ;;
      custom_5_cmd) custom_5_cmd=$v ;;
      custom_6_name) custom_6_name=$v ;;
      custom_6_cmd) custom_6_cmd=$v ;;
      log_max_kb) log_max_kb=$v ;;
    esac
  done < "$XSK_CONF"
  return 0
}

# ---------------- 输入设备枚举 ----------------
# 输出: node \t name \t vid \t pid \t KEY位图
xsk_list_key_devices() {
  awk '
    /^I: Bus=/ {
      n=split($0, a, " ")
      for (i=1; i<=n; i++) {
        if (a[i] ~ /^Vendor=/)  vid=substr(a[i], 8)
        if (a[i] ~ /^Product=/) pid=substr(a[i], 9)
      }
    }
    /^N: Name=/ { name=$0; sub(/^N: Name="/, "", name); sub(/"$/, "", name) }
    /^H: Handlers=/ {
      h=$0; sub(/^H: Handlers=/, "", h)
      node=""
      n=split(h, ha, " ")
      for (i=1; i<=n; i++) if (ha[i] ~ /^event/) node="/dev/input/" ha[i]
    }
    /^B: KEY=/ { key=$0; sub(/^B: KEY=/, "", key) }
    /^$/ {
      if (name != "" && node != "") print node "\t" name "\t" vid "\t" pid "\t" key
      name=""; node=""; key=""; vid=""; pid=""
    }
    END { if (name != "" && node != "") print node "\t" name "\t" vid "\t" pid "\t" key }
  ' /proc/bus/input/devices 2>/dev/null
}

# 位图 -> 每行一个十进制 scancode
# 内核按 unsigned long（32/64 位）从高位到低位打印且无前导零，
# 因此逐字符解析十六进制，并推断字宽，避免 awk 浮点精度问题
xsk_scancodes_of() { # $1=位图字符串
  printf '%s\n' "$1" | awk '
    {
      n=split($0, t, " ")
      wl=32
      for (k=1; k<=n; k++) if (length(t[k]) > 8) wl=64
      for (k=1; k<=n; k++) {
        w=n-k
        s=t[k]; L=length(s)
        for (i=0; i<L; i++) {
          c=tolower(substr(s, L-i, 1))
          if (c ~ /[0-9]/) d=c+0; else d=index("abcdef", c)+9
          for (j=0; j<4; j++)
            if (int(d/(2^j)) % 2 == 1) print w*wl + i*4 + j
        }
      }
    }
  '
}

# 通过设备名查找 event 节点（/proc 不可读时回退 getevent -p）
xsk_node_by_name() { # $1=设备名
  n=$(xsk_list_key_devices 2>/dev/null | while IFS="	" read -r nd nm vid pid bitmap; do
    [ "$nm" = "$1" ] && { echo "$nd"; break; }
  done)
  [ -n "$n" ] && { echo "$n"; return 0; }
  getevent -p 2>/dev/null | awk -v want="$1" '
    /^add device/ { node=$4 }
    /name:/ {
      if (node != "") {
        l=$0
        sub(/^.*name:[ \t]*"/, "", l)
        sub(/".*$/, "", l)
        if (l == want) { print node; exit }
        node=""
      }
    }
  '
  return 0
}

# ---------------- keylayout 查找 ----------------
xsk_kl_dirs() {
  echo "/system/usr/keylayout /vendor/usr/keylayout /odm/usr/keylayout /product/usr/keylayout /system_ext/usr/keylayout"
}

# 返回"内容来源"kl：设备专属 kl 优先，否则运行时实际生效的 Generic.kl
xsk_find_kl() { # $1=设备名 $2=vid $3=pid -> echo 路径
  namekl=$(printf '%s' "$1" | tr ' ' '_')
  dirs=$(xsk_kl_dirs)
  for d in $dirs; do
    [ -f "$d/$namekl.kl" ] && { echo "$d/$namekl.kl"; return 0; }
  done
  for d in $dirs; do
    if [ -n "$2" ] && [ -n "$3" ] && [ -f "$d/Vendor_${2}_Product_${3}.kl" ]; then
      echo "$d/Vendor_${2}_Product_${3}.kl"; return 0
    fi
  done
  for d in $dirs; do
    [ -f "$d/Generic.kl" ] && { echo "$d/Generic.kl"; return 0; }
  done
  return 1
}

# ---------------- 侧键自动检测 ----------------
# 输出 key=value 行。xpeng 实测: gpio-keys 只有 VOLUMEUP(115)+SEARCH(217)，
# 排除已知键后 217 是唯一候选，可高置信锁定。
xsk_detect_side_key() {
  xsk_boot_init
  if [ ! -r /proc/bus/input/devices ]; then
    # /proc 受限（如 adb shell 未提权），仅按已验证设备名回退
    node=$(xsk_node_by_name "gpio-keys" 2>/dev/null)
    if [ -n "$node" ]; then
      echo "key_device_name=gpio-keys"
      echo "key_device_node=$node"
      echo "detection_confident=0"
      return 0
    fi
    echo "detection_confident=0"
    return 1
  fi
  cand="$XSK_RUND/detect.cands"
  : > "$cand" 2>/dev/null
  excl=" 1 113 114 115 116 152 164 165 166 167 212 216 217 224 225 524 528 740 741 "
  xsk_list_key_devices | while IFS="	" read -r node name vid pid bitmap; do
    score=0
    case "$name" in
      *gpio-keys*) score=2 ;;
      *[kK]ey*|*[kK]eys*) score=1 ;;
      *) continue ;;
    esac
    for sc in $(xsk_scancodes_of "$bitmap"); do
      case "$excl" in *" $sc "*) continue ;; esac
      printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$score" "$node" "$name" "$vid" "$pid" "$sc" >> "$cand"
    done
  done
  best_score=-1; best_line=""; cnt=0
  while IFS="	" read -r score node name vid pid sc; do
    if [ "$score" -gt "$best_score" ]; then
      best_score=$score; best_line="$score	$node	$name	$vid	$pid	$sc"; cnt=1
    elif [ "$score" -eq "$best_score" ]; then
      cnt=$((cnt+1)); best_line="$score	$node	$name	$vid	$pid	$sc"
    fi
  done < "$cand"
  rm -f "$cand" 2>/dev/null
  if [ -z "$best_line" ]; then
    echo "detection_confident=0"
    return 1
  fi
  score=$(printf '%s' "$best_line" | cut -f1)
  node=$(printf '%s' "$best_line" | cut -f2)
  name=$(printf '%s' "$best_line" | cut -f3)
  vid=$(printf '%s' "$best_line" | cut -f4)
  pid=$(printf '%s' "$best_line" | cut -f5)
  sc=$(printf '%s' "$best_line" | cut -f6)
  confident=0
  [ "$cnt" -eq 1 ] && confident=1
  kl=$(xsk_find_kl "$name" "$vid" "$pid" 2>/dev/null)
  if [ -n "$kl" ] && grep -qE "^key[[:space:]]+($sc|0[xX]$(printf '%x' "$sc"))([[:space:]]|$)" "$kl" 2>/dev/null; then
    confident=1
  fi
  namekl=$(printf '%s' "$name" | tr ' ' '_')
  echo "key_device_node=$node"
  echo "key_device_name=$name"
  echo "key_vid=$vid"
  echo "key_pid=$pid"
  echo "key_scancode=$sc"
  if [ -n "$kl" ]; then
    echo "kl_source=$kl"
    case "$kl" in
      # 源是 Generic.kl 时不要覆盖全局 Generic.kl，
      # 而是生成设备专属 <name>.kl（框架按设备名优先加载，音量键等其余映射保持原样）
      */Generic.kl) echo "kl_overlay_rel=system/usr/keylayout/${namekl}.kl" ;;
      *)            echo "kl_overlay_rel=${kl#/}" ;;
    esac
  fi
  echo "detection_confident=$confident"
  return 0
}

# ---------------- keylayout overlay 生成 ----------------
# 将源 .kl 中侧键 scancode 的映射改为 remap_keycode_name（默认 UNKNOWN），
# 框架层不再产生原始 keycode，Moto Actions/系统处理从此收不到该键。
# overlay 位于模块 system/ 目录，卸载模块即自动还原。
# 注意：Android .kl 的 keycode 字段是 AKEYCODE_* 标签（无 KEY_ 前缀），
# Android 没有 F24 键码，故默认用 UNKNOWN。
xsk_gen_kl_overlay() {
  xsk_load_conf
  if [ "$remap_enabled" != "1" ] || [ -z "$kl_source" ] || [ ! -f "$kl_source" ] || [ -z "$key_scancode" ]; then
    if [ -n "$kl_overlay_rel" ]; then
      rm -f "$XSK_MODDIR/system/$kl_overlay_rel" 2>/dev/null
    fi
    xsk_log KL "overlay skipped (remap=$remap_enabled kl=$kl_source sc=$key_scancode)"
    return 0
  fi
  dst="$XSK_MODDIR/system/$kl_overlay_rel"
  case "$dst" in
    */usr/keylayout/*) ;; *usr/keylayout/*) ;;
    *) xsk_log KL "refuse non-keylayout overlay path: $dst"; return 1 ;;
  esac
  mkdir -p "${dst%/*}" 2>/dev/null || return 1
  awk -v sc="$key_scancode" -v newname="$remap_keycode_name" '
    function hex2dec(s, r, i, c) {
      s=tolower(s); r=0
      for (i=1; i<=length(s); i++) {
        c=substr(s, i, 1)
        r=r*16+((c ~ /[0-9]/) ? c+0 : (index("abcdef", c)+9))
      }
      return r
    }
    BEGIN { print "# XpengSideKey keylayout overlay (auto-generated, remove module to restore)" }
    {
      if (!hit && tolower($1) == "key") {
        v=$2
        dec = (v ~ /^0[xX]/) ? hex2dec(substr(v, 3)) : v+0
        if (dec == sc+0) {
          line="key " $2 " " newname
          for (i=3; i<=NF; i++) line=line " " $i
          print line
          hit=1
          next
        }
      }
      print
    }
    END { if (!hit) print "key " sc " " newname }
  ' "$kl_source" > "$dst.tmp" 2>/dev/null && mv -f "$dst.tmp" "$dst" 2>/dev/null
  rc=$?
  [ $rc -eq 0 ] && xsk_log KL "overlay generated: $dst (sc=$key_scancode -> $remap_keycode_name)"
  return $rc
}

# ---------------- 按键学习（WebUI 触发，用户按压侧键捕获键值） ----------------
xsk_learn_capture() { # $1=秒数
  secs=${1:-12}
  rm -f "$XSK_RUND/learn.result"
  : > "$XSK_RUND/learn.state"
  excl=" 0 113 114 115 116 "
  # toybox getevent 不支持 -c 事件计数参数（会导致立即退出、无法捕捉），
  # 改用 timeout 控制时长；捕获成功后 while 退出，getevent 随 SIGPIPE 自然结束
  timeout "$secs" getevent /dev/input/event* 2>/dev/null | while read -r a b c d; do
    case "$a" in
      /dev/input/*) t=$b; code=$c; val=$d; node=${a%:} ;;
      *) t=$a; code=$b; val=$c; node="" ;;
    esac
    [ "$t" = "0001" ] || [ "$t" = "0x0001" ] || continue
    [ "$val" = "00000001" ] || [ "$val" = "0x00000001" ] || continue
    cd=$((0x$code)) 2>/dev/null || continue
    case "$excl" in *" $cd "*) continue ;; esac
    printf '%s %s\n' "$cd" "$node" > "$XSK_RUND/learn.result"
    break
  done
  rm -f "$XSK_RUND/learn.state" 2>/dev/null
  return 0
}

xsk_learn_start() { # $1=秒数
  [ -f "$XSK_RUND/learn.state" ] && return 1
  xsk_boot_init
  S=""
  command -v setsid >/dev/null 2>&1 && S="setsid"
  nohup $S sh "$XSK_BASE/tools.sh" learn_run "${1:-12}" >/dev/null 2>&1 &
  return 0
}

xsk_learn_cancel() {
  rm -f "$XSK_RUND/learn.state" "$XSK_RUND/learn.result" "$XSK_RUND/learn.request" 2>/dev/null
  return 0
}

# ---------------- 诊断（需求文档中的强制验证命令） ----------------
xsk_diagnose() {
  echo "### [1/7] 输入设备与按键能力 (getevent -pl 摘要)"
  getevent -pl 2>/dev/null | sed -n '1,160p'
  echo ""
  echo "### [2/7] /proc/bus/input/devices (key 设备)"
  if [ -r /proc/bus/input/devices ]; then
    xsk_list_key_devices 2>/dev/null | cut -c1-220
  else
    echo "(不可读，回退 getevent -p 设备名)"
    xsk_nodes_via_getevent 2>/dev/null
  fi
  echo ""
  echo "### [3/7] dumpsys input 关键词过滤"
  dumpsys input 2>/dev/null | grep -iE "xpeng|smart|side|gpio|KeyLayoutFile" | sed -n '1,40p'
  echo ""
  echo "### [4/7] keylayout 文件清单"
  for d in $(xsk_kl_dirs); do
    [ -d "$d" ] && { echo "-- $d"; ls "$d" 2>/dev/null; }
  done
  echo ""
  echo "### [5/7] Moto 相关应用"
  pm list packages 2>/dev/null | grep -iE "moto|actions" | sed -n '1,20p'
  ls -d /system/priv-app/MotoActions /vendor/app/MotoKey /product/app/MotoActions 2>/dev/null
  echo ""
  echo "### [6/7] /dev/input SELinux 上下文"
  ls -Z /dev/input/event* 2>/dev/null | sed -n '1,30p'
  echo ""
  echo "### [7/7] 近期 avc 拒绝日志 (dmesg 受限时空)"
  dmesg 2>/dev/null | grep -i avc | tail -n 20
  return 0
}

xsk_nodes_via_getevent() {
  getevent -p 2>/dev/null | awk '
    /^add device/ { node=$4 }
    /name:/ {
      if (node != "") {
        l=$0
        sub(/^.*name:[ \t]*"/, "", l)
        sub(/".*$/, "", l)
        print node "\t" l
        node=""
      }
    }
  '
}

# ---------------- 元模块检测 ----------------
# 新版 KernelSU 将挂载外包给元模块(meta-overlayfs 等)；
# 无元模块时 system/ overlay 不挂载，模块自动降级为纯脚本模式
xsk_meta_active() {
  if [ -e /data/adb/metamodule ]; then return 0; fi
  grep -qs "metamodule=1" /data/adb/modules/*/module.prop 2>/dev/null && return 0
  return 1
}

# ---------------- 守护进程控制 ----------------
xsk_daemon_pid() {
  cat "$XSK_RUND/daemon.pid" 2>/dev/null | tr -d ' \r\n'
}

xsk_daemon_running() {
  p=$(xsk_daemon_pid)
  [ -n "$p" ] && [ -d "/proc/$p" ]
}

xsk_daemon_stop() {
  p=$(xsk_daemon_pid)
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then
    gp=$(cat "$XSK_RUND/getevent.pid" 2>/dev/null | tr -d ' \r\n')
    kill "$p" 2>/dev/null
    [ -n "$gp" ] && kill "$gp" 2>/dev/null
    i=0
    while [ "$i" -lt 10 ] && [ -d "/proc/$p" ]; do sleep 0.1; i=$((i+1)); done
    kill -9 "$p" 2>/dev/null
    xsk_log DAEMON "stopped (pid $p)"
  fi
  rm -f "$XSK_RUND/daemon.pid" "$XSK_RUND/getevent.pid" 2>/dev/null
  return 0
}

xsk_daemon_start() {
  xsk_daemon_stop
  if [ -f "$XSK_MODDIR/disable" ]; then
    xsk_log DAEMON "module disabled by manager, skip"
    return 1
  fi
  xsk_load_conf
  if [ "$enabled" != "1" ]; then
    xsk_log DAEMON "disabled in config, skip"
    return 1
  fi
  S=""
  command -v setsid >/dev/null 2>&1 && S="setsid"
  nohup $S sh "$XSK_BASE/daemon.sh" >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 20 ]; do
    [ -f "$XSK_RUND/daemon.pid" ] && break
    sleep 0.1; i=$((i+1))
  done
  if xsk_daemon_running; then
    xsk_log DAEMON "started (pid $(xsk_daemon_pid))"
    return 0
  fi
  xsk_log DAEMON "start failed"
  return 1
}

xsk_daemon_restart() {
  xsk_daemon_start
}

# 看门狗：守护进程意外退出/僵死时自动拉起（幂等）
xsk_watchdog_start() {
  wp=$(cat "$XSK_RUND/watchdog.pid" 2>/dev/null | tr -d ' \r\n')
  [ -n "$wp" ] && [ -d "/proc/$wp" ] && return 0
  S=""
  command -v setsid >/dev/null 2>&1 && S="setsid"
  nohup $S sh "$XSK_BASE/watchdog.sh" >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 20 ]; do
    [ -f "$XSK_RUND/watchdog.pid" ] && break
    sleep 0.1; i=$((i+1))
  done
  xsk_log WATCHDOG "watchdog started"
  return 0
}

# ---------------- 作为脚本执行时的入口 ----------------
# 被 source 时 $0 是调用者文件名，不会进入本分支
if [ "${0##*/}" = "tools.sh" ]; then
  case "$1" in
    learn_run)    xsk_learn_capture "${2:-12}" ;;
    learn_start)  xsk_learn_start "${2:-12}" ;;
    detect)       xsk_detect_side_key ;;
    gen_kl)       xsk_gen_kl_overlay ;;
    diagnose)     xsk_diagnose ;;
    daemon_start) xsk_daemon_start ;;
    daemon_stop)  xsk_daemon_stop ;;
    *) echo "usage: tools.sh {learn_run|learn_start|detect|gen_kl|diagnose|daemon_start|daemon_stop}" ;;
  esac
  exit 0
fi
