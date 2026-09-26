#!/system/bin/sh
# =============================================================
# XpengSideKey 安装脚本 (customize.sh)
# 1) 机型+系统强校验  2) 验证 keylayout 路径  3) 生成 keylayout overlay
# 本脚本由 KernelSU/Magisk 安装器以 root 执行，MODPATH 指向模块目录
# =============================================================
umask 022

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort >/dev/null 2>&1 || abort() { ui_print "$1"; exit 1; }

MODDIR="${MODPATH:-${0%/*}}"
[ -f "$MODDIR/module.prop" ] || MODDIR=$(pwd)
export XSK_MODDIR="$MODDIR"
PDIR="$MODDIR/xpengsidekey"

ui_print "========================================"
ui_print "  MotoS30侧键魔方 v1.0.3"
ui_print "  机型: Motorola Edge S30 (xpeng)"
ui_print "  系统: Android 16+  管理器: KernelSU"
ui_print "========================================"

# ---------- 1. 机型与系统强校验 ----------
device=$(getprop ro.product.device)
model=$(getprop ro.product.model)
release=$(getprop ro.build.version.release)
sdk=$(getprop ro.build.version.sdk)
ui_print "- 设备: $device ($model)  Android $release (SDK $sdk)"

if [ -f /data/adb/xpengsidekey_force ]; then
  ui_print "! 检测到 xpengsidekey_force，跳过机型校验（仅限测试）"
else
  if [ "$device" != "xpeng" ]; then
    ui_print "! 设备校验失败: ro.product.device = $device"
    ui_print "! 本模块仅适配 Motorola Edge S30 (xpeng)"
    abort "! 确要强装: touch /data/adb/xpengsidekey_force 后重试"
  fi
  if [ -z "$sdk" ] || [ "$sdk" -lt 36 ]; then
    ui_print "! 系统校验失败: Android $release (SDK ${sdk:-?})"
    abort "! 本模块需要 Android 16 (SDK 36+)"
  fi
fi

# ---------- 2. 解压后权限修正 ----------
# webroot/ 权限由管理器自动设置（官方规范），此处跳过
find "$MODDIR" -name "*.sh" -not -path "*/webroot/*" -exec chmod 755 {} \; 2>/dev/null
chmod 644 "$MODDIR/module.prop" 2>/dev/null
chmod 644 "$PDIR/config.prop" 2>/dev/null
mkdir -p "$PDIR/logs" "$PDIR/run" 2>/dev/null

# ---------- 3. 覆盖安装/迁移时保留旧配置 ----------
oldconf_new=/data/adb/modules/xpengsidekey/xpendsidekey/config.prop
oldconf_old=/data/adb/modules/xpendsidekey/xpendsidekey/config.prop
if [ -f "$oldconf_new" ] && [ ! -f "$PDIR/config.prop" ]; then
  cp -f "$oldconf_new" "$PDIR/config.prop" 2>/dev/null
  ui_print "- 已保留旧配置"
elif [ -f "$oldconf_old" ] && [ ! -f "$PDIR/config.prop" ]; then
  cp -f "$oldconf_old" "$PDIR/config.prop" 2>/dev/null
  ui_print "- 已从旧 ID 模块(xpendsidekey)迁移配置"
fi
if [ -d /data/adb/modules/xpendsidekey ]; then
  ui_print "! 检测到旧 ID 模块 xpendsidekey"
  ui_print "! 请在管理器中卸载它并重启，避免双重守护冲突"
fi

# ---------- 4. 加载函数库与默认配置 ----------
. "$PDIR/tools.sh"
xsk_boot_init
xsk_load_conf

# 确保所有配置键存在（保留用户旧值，仅补缺失项）
set_def() {
  [ -z "$(xsk_conf_get "$1")" ] && xsk_conf_set "$1" "$2"
  return 0
}
set_def enabled 1
set_def haptic 1
set_def remap_enabled 1
set_def remap_keycode 0
set_def remap_keycode_name UNKNOWN
set_def click_gap_ms 300
set_def long_press_ms 550
set_def bind_single wechat_scan
set_def bind_double wechat_pay
set_def bind_long ringer_cycle
set_def custom_single_cmd ""
set_def custom_double_cmd ""
set_def custom_long_cmd ""
set_def log_max_kb 256

# ---------- 5. 侧键检测（xpeng 实测已预置 217/gpio-keys，检测仅复核） ----------
ui_print "- 正在复核侧键输入设备..."
det=$("$PDIR/tools.sh" detect 2>/dev/null)
det_sc=""
if [ -n "$det" ]; then
  printf '%s\n' "$det" | while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    [ "$k" = "$l" ] && continue
    case "$k" in
      key_device_node|key_device_name|key_vid|key_pid|key_scancode|kl_source|kl_overlay_rel|detection_confident)
        [ -n "$v" ] && xsk_conf_set "$k" "$v"
        ;;
    esac
  done
  det_sc=$(printf '%s\n' "$det" | sed -n 's/^key_scancode=//p')
fi
xsk_load_conf
if [ -n "$key_scancode" ]; then
  ui_print "- 侧键: $key_device_name ($key_device_node) scancode=$key_scancode"
  [ "$detection_confident" = "1" ] || ui_print "! 检测置信度低，可在 WebUI 中[学习按键]校准"
else
  ui_print "! 未能识别侧键键值，请安装后在 WebUI 中使用[学习按键]"
fi

# ---------- 6. 验证 keylayout 并生成 overlay ----------
xsk_gen_kl_overlay
if [ -f "$MODDIR/system/$kl_overlay_rel" ]; then
  ui_print "- 键位映射 overlay: $kl_overlay_rel"
  ui_print "- 规则: key $key_scancode -> $remap_keycode_name (systemless)"
else
  ui_print "! 未生成 keylayout overlay (源: $kl_source)"
  ui_print "! 不影响守护进程监听，但无法屏蔽系统默认行为"
fi

# ---------- 6.5 元模块状态检测 ----------
if xsk_meta_active; then
  ui_print "- 已检测到元模块: overlay 将随模块挂载生效"
else
  ui_print "! 未检测到元模块 (如 meta-overlayfs): 纯脚本模式"
  ui_print "! 守护进程/绑定/自定义命令均不受影响"
  ui_print "! 仅键位重映射(屏蔽系统默认键行为)暂不生效"
  ui_print "! 日后安装元模块并重启即可自动启用"
fi

# ---------- 7. 完成提示 ----------
ui_print "- 守护进程将在重启后自动运行 (service.sh)"
ui_print "- 绑定/功能/日志: KernelSU 管理器 -> 模块 -> WebUI"
ui_print "- 卸载即完全复原: overlay 随模块自动移除"
ui_print "========================================"
exit 0
