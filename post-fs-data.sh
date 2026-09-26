#!/system/bin/sh
# XpengSideKey post-fs-data: 在 KernelSU 挂载模块 overlay 之前
# 按当前配置重新生成 keylayout overlay，使配置改动于本次启动生效
MODDIR=/data/adb/modules/xpengsidekey
BASE="$MODDIR/xpengsidekey"
[ -f "$BASE/tools.sh" ] || exit 0
XSK_LOG_MAX_KB=128
. "$BASE/tools.sh"
xsk_gen_kl_overlay
exit 0
