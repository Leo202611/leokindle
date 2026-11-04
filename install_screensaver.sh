#!/bin/sh
# 把 bg_ss00.png 安装为 linkss 屏保（固件 5.16.x / Kindle 8 竖屏 600x800 8位灰度）。
# 前置：已安装 ScreenSavers Hack (linkss)，目录 /mnt/us/linkss/screensavers/ 存在。
# 用法：KUAL 菜单「设为屏保」点一下即可；或 sh install_screensaver.sh。
set -e
DST="/mnt/us/dash"
# 优先用定时更新拉下来的实时图；bg_ss00.png 只是 deploy 附带的静态兜底图
# （2026-11-04 之前那张是中午 12:00 生成的，用户看到的旧画面就是它）。
SRC="$DST/bg_ss00.png"
[ -s "$DST/ss_current.png" ] && SRC="$DST/ss_current.png"
LINK_DIR="/mnt/us/linkss/screensavers"
LOG="$DST/screensaver.log"
SRV="${DASH_SRV:-192.168.110.46:8899}"
GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG"; }
# od 各版本分隔符可能是一格或两格空格，去空格后比十六进制串才可靠
png_ok() { [ "$(head -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; }

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

# linkss 源码（bin/shuffless）确认的命名规则：
#   - 它会把 screensavers/ 里所有 PNG 自动重命名为 bg_ss + 两位序号 + .png
#   - 硬性要求：必须是**小写 .png**，其它文件会被丢进 discarded/
#   - 安装时自带示例图 00_you_can_delete_me*.png，若不清理会与我们的图轮播交替
# 所以这里把目录里其它 .png 全部移到备份目录，只留我们这一张，保证休眠时
# 100% 显示指定画面（单文件时序号必为 00）。
BK_DIR="/mnt/us/linkss/backup_custom"
mkdir -p "$BK_DIR" 2>/dev/null
for f in "$LINK_DIR"/*.png; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in bg_ss00.png) continue ;; esac
    mv "$f" "$BK_DIR/" 2>/dev/null && say "移走示例/旧图: $(basename "$f")"
done

# 备份已有，再覆盖（保留 .bak 便于回退）
[ -f "$LINK_DIR/bg_ss00.png" ] && cp "$LINK_DIR/bg_ss00.png" "$BK_DIR/bg_ss00.png.bak" 2>/dev/null
cp "$SRC" "$LINK_DIR/bg_ss00.png"
say "已写入 $LINK_DIR/bg_ss00.png（600x800 8位灰度，目录内仅此一张）"

# 立即在屏上绘制预览（即便不休眠也能看到；休眠时 linkss 也会读取此图）
eips -f -g "$LINK_DIR/bg_ss00.png" >> "$LOG" 2>&1
say "完成：休眠即显示此图。若之后放了多张，linkss 会在 framework 重启时自动编号轮播。"
