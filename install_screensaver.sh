#!/bin/sh
# 把 bg_ss00.png 安装为 linkss 屏保（固件 5.16.x / Kindle 8 竖屏 600x800 8位灰度）。
# 前置：已安装 ScreenSavers Hack (linkss)，目录 /mnt/us/linkss/screensavers/ 存在。
# 用法：KUAL 菜单「设为屏保」点一下即可；或 sh install_screensaver.sh。
set -e
DST="/mnt/us/dash"
SRC="$DST/bg_ss00.png"
LINK_DIR="/mnt/us/linkss/screensavers"
LOG="$DST/screensaver.log"
SRV="${DASH_SRV:-192.168.110.46:8899}"
GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG"; }
png_ok() { head -c 8 "$1" 2>/dev/null | od -An -tx1 | grep -q '89 50 4e 47'; }

say "===== 设为屏保 ====="

# 源图缺失则尝试下载（电脑 HTTP -> GitHub main）
if [ ! -s "$SRC" ]; then
    say "本地无 bg_ss00.png，尝试下载"
    if curl -sL -m 40 -o "$SRC.tmp" "http://$SRV/bg_ss00.png" 2>/dev/null \
       && [ -s "$SRC.tmp" ] && png_ok "$SRC.tmp"; then
        mv "$SRC.tmp" "$SRC"; say "OK 从电脑拉到 bg_ss00.png"
    else
        rm -f "$SRC.tmp"
        curl -sL -m 40 -H "Accept: application/vnd.github.raw" -o "$SRC.tmp" \
             "$GH_API/bg_ss00.png?ref=main" 2>/dev/null
        if [ -s "$SRC.tmp" ] && png_ok "$SRC.tmp"; then
            mv "$SRC.tmp" "$SRC"; say "OK 从 GitHub 拉到 bg_ss00.png"
        else
            rm -f "$SRC.tmp"
            say "FAIL 无法获取 bg_ss00.png（请先 deploy / 在线更新）"; exit 1
        fi
    fi
fi

# linkss 必须已安装，否则没有目标目录
if [ ! -d "$LINK_DIR" ]; then
    say "找不到 $LINK_DIR —— 请先装 linkss（ScreenSavers Hack）："
    say "  1) 已装 MRPI + KUAL 的前提下，把 Update_linkss_*.bin 放进 mrpackages；"
    say "  2) Kindle 搜索框输入 ;log mrpi 安装，重启后即出现该目录；"
    say "  3) 注意：USBNetwork/usbnet 会与 linkss 冲突，装了需重装 linkss。"
    exit 2
fi

# 备份已有，再覆盖（保留 .bak 便于回退）
[ -f "$LINK_DIR/bg_ss00.png" ] && cp "$LINK_DIR/bg_ss00.png" "$LINK_DIR/bg_ss00.png.bak" 2>/dev/null
cp "$SRC" "$LINK_DIR/bg_ss00.png"
say "已写入 $LINK_DIR/bg_ss00.png"

# 立即在屏上绘制预览（即便不休眠也能看到；休眠时 linkss 也会读取此图）
eips -f -g "$LINK_DIR/bg_ss00.png" >> "$LOG" 2>&1
say "完成：休眠即显示此图。需多张轮播，按 bg_ssNN.png 规则再放几张即可。"
