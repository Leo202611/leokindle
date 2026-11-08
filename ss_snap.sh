#!/bin/sh
# 手动上传「应显示」的屏保图文件（KUAL 菜单项 14）。
#
# 注意：手动进 KUAL 时设备处于活跃态，/dev/fb0 此刻是 KUAL 菜单而非屏保，
# 故此处只上传「本应显示」的图文件（ss_current.png，即上一次自动更新 eips 的画面），
# 供 Mac 端免拍照核对「图本身对不对」。
# 要看「屏保实拍」（帧缓冲真实像素），请用自动更新后的截图：调度器每次刷屏后会
# 自动抓 /dev/fb0 上传到同一 topic（见 ss_update_once.sh 的 snap_fb）。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_SNAP_TOPIC:-}" ] || SS_SNAP_TOPIC="k8dash_snap_3f9a2c"
SS_SNAP_URL="https://ntfy.sh/$SS_SNAP_TOPIC"
SS_INSECURE="${SS_INSECURE:-1}"
CK=""
[ "$SS_INSECURE" = "1" ] && CK="-k"
SS_DST_DIR="${SS_DST_DIR:-/mnt/us/dash}"
SS_LINK_DIR="${SS_LINK_DIR:-/mnt/us/linkss/screensavers}"
SS_FILE="${SS_FILE:-bg_ss00.png}"

log() { echo "[$(date +'%m-%d %H:%M:%S')] $*"; }

# 优先 ss_current.png（上次 eips 的画面）；退而取 linkss 屏保文件
SRC="$SS_DST_DIR/ss_current.png"
[ -s "$SRC" ] || SRC="$SS_LINK_DIR/$SS_FILE"
[ -s "$SRC" ] || { log "没有可上传的屏保图($SRC)"; exit 1; }

# 确认是合法 600x800 8位灰度 PNG（与屏保规范一致）
MAGIC=$(head -c 8 "$SRC" 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "89504e470d0a1a0a" ] || { log "非 PNG，放弃: $SRC"; exit 1; }

HH=$(date +'%m-%d %H:%M')
if curl -sL $CK -T "$SRC" -H "Title: 屏保应显示图(file) $HH" \
     -H "Filename: ss_current.png" -H "Content-Type: image/png" "$SS_SNAP_URL" 2>/dev/null; then
    log "已上传应显示图: $SRC -> ntfy($SS_SNAP_TOPIC)"
else
    log "上传失败"
    exit 1
fi
