#!/bin/sh
# Kindle 仪表盘 v5 · 纯 WiFi 一键安装器
#
# 【项目约定】所有进入 Kindle 的文件一律通过 WiFi 传输，不使用 USB 数据线。
# 用户设备的数据线无法挂载（USB Mass Storage 不枚举），此路径已废弃。
#
# ---- 在 Kindle 上执行（任何能跑 shell 的入口：KTerm / KUAL 命令项）----
#
# 用法 A（推荐，脚本不落盘、直接管道执行）：
#   curl -sL http://192.168.110.46:8899/deploy_v5.sh | sh -s land
#
# 用法 B（先落盘再执行，便于中断重试）：
#   curl -sL -o /tmp/wifi_install.sh http://192.168.110.46:8899/deploy_v5.sh \
#     && sh /tmp/wifi_install.sh land
#
# 用法 C（完全不依赖电脑，只走 GitHub）：
#   curl -sL -H "Accept: application/vnd.github.raw" \
#     "https://api.github.com/repos/Leo202611/leokindle/contents/deploy_v5.sh?ref=main" \
#     | sh -s land
#
# 参数：start=沿用版式启动 / land=横屏启动 / port=竖屏启动 / 空=只安装不启动
# Mac IP 变了可用环境变量覆盖：DASH_SRV=192.168.x.x:8899
#
# ---- 本安装器经 WiFi 装入的全部文件（双源：电脑 HTTP -> GitHub）----
#   /mnt/us/dash/dashd_v5.sh            守护进程
#   /mnt/us/dash/dash_on_v5.sh          启动（沿用版式）
#   /mnt/us/dash/dash_on_land.sh        横屏启动
#   /mnt/us/dash/dash_on_port.sh        竖屏启动
#   /mnt/us/dash/dash_off.sh            关闭
#   /mnt/us/dash/dash_update.sh         在线更新（KUAL 点一下即可，无需电脑/终端）
#   /mnt/us/dash/cur_p.png              竖屏缓存图
#   /mnt/us/dash/cur_l.png              横屏缓存图
#   /mnt/us/extensions/dash/bin/*.sh    KUAL 入口（由上面拷贝）
#   /mnt/us/extensions/dash/menu.json   菜单（本地生成，不依赖设备上任何遗留文件）
#
# 电量链路当前默认停用（2026-11-04 12:37 用户要求省电）：
#   dashd_v5.sh 的 BATT_REPORT=0 → 不读电量、不 POST、也不做 :35 跟进取图；
#   画面右下电量位留白。代码与开关都保留，以后可恢复。
# 因此本安装器下发的守护脚本必须是最新版，旧版仍会每小时上报耗电。
# 覆盖采用 mv（替换目录项），正在运行的旧实例仍持旧 inode，不会读坏脚本。
#
# 电脑端服务：wifi_srv/ 目录 + python3 -m http.server 8899
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

SRV="${DASH_SRV:-192.168.110.46:8899}"
GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
LOG=/mnt/us/dash/deploy_v5.log
DST=/mnt/us/dash
EXT=/mnt/us/extensions/dash

say() {
    echo "$*" >> "$LOG" 2>/dev/null
    echo "$*"
}

# 脚本类文件：必须全部经 WiFi 下发，一个都不能依赖 USB 预置
SH_FILES="dashd_v5.sh dash_on_v5.sh dash_on_land.sh dash_on_port.sh dash_off.sh dash_update.sh"
# 其中需要装进 KUAL bin/ 的入口
ENTRIES="dash_on_v5.sh dash_on_land.sh dash_on_port.sh dash_off.sh dash_update.sh"

mkdir -p "$DST" "$EXT/bin" 2>/dev/null
: > "$LOG" 2>/dev/null
say "===== v5 纯 WiFi 安装 ====="
say "时刻: $(date)"
say "源: http://$SRV  (回退: GitHub main/dash)"

# ---- 通用校验 ----
png_ok() { head -c 8 "$1" 2>/dev/null | od -An -tx1 | grep -q '89 50 4e 47'; }

gh_raw() {
    # $1=文件名 $2=分支 $3=输出路径
    curl -sL -m 40 -H "Accept: application/vnd.github.raw" \
         -o "$3" "$GH_API/$1?ref=$2" 2>/dev/null
}

# ---- 1. 拉脚本（电脑 HTTP -> GitHub main）----
pull_sh() {
    f="$1"
    if curl -sL -m 30 -o "$DST/$f.tmp" "http://$SRV/$f" 2>/dev/null; then
        sz=$(wc -c < "$DST/$f.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 200 ] && head -c 60 "$DST/$f.tmp" | grep -q '#!/bin/sh'; then
            mv "$DST/$f.tmp" "$DST/$f"; chmod 755 "$DST/$f"
            say "OK  $f (电脑, $sz bytes)"; return 0
        fi
    fi
    rm -f "$DST/$f.tmp"
    if gh_raw "$f" main "$DST/$f.tmp"; then
        sz=$(wc -c < "$DST/$f.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 200 ] && head -c 60 "$DST/$f.tmp" | grep -q '#!/bin/sh'; then
            mv "$DST/$f.tmp" "$DST/$f"; chmod 755 "$DST/$f"
            say "OK  $f (GitHub/main, $sz bytes)"; return 0
        fi
    fi
    rm -f "$DST/$f.tmp"
    say "FAIL $f 两个来源都失败"
    return 1
}

for f in $SH_FILES; do pull_sh "$f"; done

# ---- 2. 拉图（电脑 HTTP -> GitHub 当小时 -> GitHub index 最新）----
# 第三层很重要：Kindle 设备时钟可能不准（校时失败时），
# 按本机小时拼出的文件名在 dash 分支上不一定存在。
gh_png() {
    fn="$1"; out="$2"
    if gh_raw "$fn" dash "$out"; then
        sz=$(wc -c < "$out" 2>/dev/null)
        if [ "${sz:-0}" -gt 10000 ] && png_ok "$out"; then return 0; fi
    fi
    return 1
}

pull_png() {
    dst="$1"; land="$2"
    # 2a. 电脑 HTTP（刚渲染好的当小时图，最快）
    if curl -sL -m 40 -o "$dst.tmp" "http://$SRV/$dst" 2>/dev/null; then
        sz=$(wc -c < "$dst.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 10000 ] && png_ok "$dst.tmp"; then
            mv "$dst.tmp" "$dst"; say "OK  $dst (电脑, $sz bytes)"; return 0
        fi
    fi
    rm -f "$dst.tmp"
    # 2b. GitHub 按设备当前小时
    h=$(date +%Y%m%d_%H)
    [ -n "$land" ] && h="${h}_land"
    if gh_png "$h.png" "$dst.tmp"; then
        sz=$(wc -c < "$dst.tmp"); mv "$dst.tmp" "$dst"
        say "OK  $dst (GitHub/$h.png, $sz bytes)"; return 0
    fi
    rm -f "$dst.tmp"
    # 2c. GitHub index.txt 里最新的一张
    IDX="$DST/.index_wifi"
    if gh_raw "index.txt" dash "$IDX" && [ -s "$IDX" ]; then
        if [ -n "$land" ]; then
            fn=$(grep '_land\.png' "$IDX" | tail -1)
        else
            fn=$(grep '\.png' "$IDX" | grep -v '_land' | tail -1)
        fi
        if [ -n "$fn" ] && gh_png "$fn" "$dst.tmp"; then
            sz=$(wc -c < "$dst.tmp"); mv "$dst.tmp" "$dst"
            say "OK  $dst (GitHub/最新 $fn, $sz bytes)"; return 0
        fi
    fi
    rm -f "$dst.tmp" "$IDX"
    say "FAIL $dst 所有来源都失败"
    return 1
}

pull_png cur_p.png ""
pull_png cur_l.png "land"

# ---- 3. 装 KUAL 入口（全部来自上面 WiFi 下载的副本）----
for e in $ENTRIES; do
    if [ -f "$DST/$e" ]; then
        # 必须「写临时文件 + mv 替换目录项」，不能直接 cp 覆盖目标：
        # 在线更新时 dash_update.sh 正在被执行，就地截断会写坏它的 inode。
        # mv 是改名，运行中的脚本仍持有旧 inode，可以安全跑完。
        cp "$DST/$e" "$EXT/bin/$e.tmp" 2>/dev/null \
            && mv "$EXT/bin/$e.tmp" "$EXT/bin/$e" 2>/dev/null \
            && chmod 755 "$EXT/bin/$e" 2>/dev/null \
            && say "OK  入口 $EXT/bin/$e" \
            || say "FAIL 安装 $e"
        rm -f "$EXT/bin/$e.tmp"
    else
        say "FAIL 源缺失 $e"
    fi
done

# ---- 4. 生成菜单 ----
# 只引用上面 5 个 WiFi 下发的入口，不再指向设备上遗留的探针/诊断脚本，
# 这样整个安装是自包含的：设备原先是什么状态都不影响。
# 第 5 项「在线更新」是长期自举钩子：装过一次 v5 之后，
# 后续所有更新都可以在 KUAL 里点一下完成，不再需要 SSH 或电脑。
MENU="$EXT/menu.json"
[ -f "$MENU" ] && cp "$MENU" "$MENU.bak_wifi" 2>/dev/null
cat > "$MENU.new" <<'JSON'
{
	"items": [
		{
			"name": "气象仪表盘 Dash",
			"priority": 1,
			"items": [
				{
					"name": "启动仪表盘(沿用版式)",
					"action": "bin/dash_on_v5.sh",
					"exitmenu": true
				},
				{
					"name": "切换为横屏",
					"action": "bin/dash_on_land.sh",
					"exitmenu": true
				},
				{
					"name": "切换为竖屏",
					"action": "bin/dash_on_port.sh",
					"exitmenu": true
				},
				{
					"name": "关闭仪表盘",
					"action": "bin/dash_off.sh",
					"exitmenu": true
				},
				{
					"name": "在线更新(WiFi)",
					"action": "bin/dash_update.sh",
					"exitmenu": true
				}
			]
		}
	]
}
JSON
mv "$MENU.new" "$MENU" && say "OK  写入 $MENU"

# ---- 5. 自检 ----
say "---- 自检 ----"
MISS=0
for f in $SH_FILES cur_p.png cur_l.png; do
    if [ -s "$DST/$f" ]; then
        say "  $f: $(wc -c < "$DST/$f") bytes"
    else
        say "  $f: 缺失"; MISS=$((MISS + 1))
    fi
done
for e in $ENTRIES; do
    if [ -s "$EXT/bin/$e" ]; then
        say "  入口 $e: OK"
    else
        say "  入口 $e: 缺失"; MISS=$((MISS + 1))
    fi
done
[ -s "$MENU" ] && say "  菜单: OK" || { say "  菜单: 缺失"; MISS=$((MISS + 1)); }
say "  缺失项合计: $MISS"

# ---- 6. 可选：立刻启动 ----
case "$1" in
    start|land|port) BOOT="$1" ;;
    *) BOOT="" ;;
esac
if [ -n "$BOOT" ]; then
    say "---- 立刻启动 ($BOOT) ----"
    case "$BOOT" in
        land) sh "$EXT/bin/dash_on_land.sh" 2>&1 | head -5 ;;
        port) sh "$EXT/bin/dash_on_port.sh" 2>&1 | head -5 ;;
        *)    sh "$EXT/bin/dash_on_v5.sh" 2>&1 | head -5 ;;
    esac
    sleep 6
    say "当前版式: $(cat $DST/orient 2>/dev/null)"
    say "守护日志尾部:"
    tail -12 "$DST/dashd.log" 2>/dev/null | sed 's/^/  /'
fi

say "===== 安装完成（全程 WiFi，未使用 USB）====="
