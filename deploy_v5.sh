#!/bin/sh
# Kindle 仪表盘 v5 · WiFi 一键部署脚本
#
# 用法（在 Kindle 的 KUAL 里执行本脚本，或用任何能跑 shell 的方式）：
#   sh /mnt/us/dash/deploy_v5.sh
#
# 它做三件事：
#   1) 从电脑的 HTTP 服务拉取 dashd_v5.sh / dash_on_v5.sh / 两张新排版图
#   2) 安装到位（脚本 + 缓存图 + KUAL 菜单项）
#   3) 打印自检结果
#
# 电脑端 HTTP 服务：python3 -m http.server 8899
# 目录：~/WorkBuddy/2026-11-01-01-37-28/kindle/dashboard/wifi_srv
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

SRV="192.168.110.46:8899"
LOG=/mnt/us/dash/deploy_v5.log
DST=/mnt/us/dash
EXT=/mnt/us/extensions/dash

say() {
    echo "$*" >> "$LOG"
    echo "$*"
}

: > "$LOG"
say "===== v5 WiFi 部署 ====="
say "时刻: $(date)"
say "源: http://$SRV"

mkdir -p "$DST" "$EXT/bin" 2>/dev/null

# ---- 1. 拉脚本 ----
# 优先电脑 HTTP；失败则从 GitHub main 分支取。
pull_sh() {
    f="$1"
    if curl -sL -m 30 -o "$DST/$f.tmp" "http://$SRV/$f"; then
        sz=$(wc -c < "$DST/$f.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 1000 ] && head -c 60 "$DST/$f.tmp" | grep -q '#!/bin/sh'; then
            mv "$DST/$f.tmp" "$DST/$f"; chmod 755 "$DST/$f"
            say "OK  $f (来自电脑, $sz bytes)"; return 0
        fi
        rm -f "$DST/$f.tmp"
    fi
    if curl -sL -m 30 -H "Accept: application/vnd.github.raw" \
         -o "$DST/$f.tmp" "https://api.github.com/repos/Leo202611/leokindle/contents/$f?ref=main"; then
        sz=$(wc -c < "$DST/$f.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 1000 ] && head -c 60 "$DST/$f.tmp" | grep -q '#!/bin/sh'; then
            mv "$DST/$f.tmp" "$DST/$f"; chmod 755 "$DST/$f"
            say "OK  $f (来自 GitHub, $sz bytes)"; return 0
        fi
    fi
    rm -f "$DST/$f.tmp"
    say "FAIL $f 两个来源都失败"
    return 1
}

pull_sh dashd_v5.sh
pull_sh dash_on_v5.sh

# ---- 2. 拉新排版图 ----
# 优先从电脑 HTTP 服务拿（那是刚渲染好的当小时图）；
# 拿不到就退回 GitHub dash 分支按小时取。
# dash 分支里是 <YYYYMMDD_HH>.png（竖屏）和 <YYYYMMDD_HH>_land.png（横屏）。
pull_png() {
    dst="$1"; land="$2"
    # 先试电脑
    if curl -sL -m 40 -o "$dst.tmp" "http://$SRV/$dst"; then
        sz=$(wc -c < "$dst.tmp" 2>/dev/null)
        if [ "${sz:-0}" -gt 10000 ]; then
            mv "$dst.tmp" "$dst"; say "OK  $dst (来自电脑, $sz bytes)"; return 0
        fi
        rm -f "$dst.tmp"
    fi
    # 退回 GitHub：按本机当前小时取
    h=$(date +%Y%m%d_%H)
    [ -n "$land" ] && h="${h}_land"
    for br in dash main; do
        if curl -sL -m 40 -H "Accept: application/vnd.github.raw" \
             -o "$dst.tmp" "https://api.github.com/repos/Leo202611/leokindle/contents/$h.png?ref=$br"; then
            sz=$(wc -c < "$dst.tmp" 2>/dev/null)
            if [ "${sz:-0}" -gt 10000 ] && head -c 8 "$dst.tmp" | od -An -tx1 | grep -q '89 50 4e 47'; then
                mv "$dst.tmp" "$dst"; say "OK  $dst (来自 GitHub/$br, $sz bytes)"; return 0
            fi
        fi
        rm -f "$dst.tmp"
    done
    say "FAIL $dst 两个来源都失败"
    return 1
}

pull_png cur_p.png ""
pull_png cur_l.png "land"

# ---- 3. 装 KUAL 入口 ----
if [ -f "$DST/dash_on_v5.sh" ]; then
    cp "$DST/dash_on_v5.sh" "$EXT/bin/dash_on_v5.sh" 2>/dev/null \
        && chmod 755 "$EXT/bin/dash_on_v5.sh" 2>/dev/null \
        && say "OK  安装 KUAL 入口 $EXT/bin/dash_on_v5.sh"
fi

# ---- 4. 更新 KUAL 菜单 ----
MENU="$EXT/menu.json"
if [ -f "$MENU" ]; then
    cp "$MENU" "$MENU.bak_v5" 2>/dev/null
    # 用 python? Kindle 上不一定有。改用直接写文件。
    cat > "$MENU.new" <<'JSON'
{
	"items": [
		{
			"name": "气象仪表盘 Dash",
			"priority": 1,
			"items": [
				{
					"name": "启动仪表盘 v5",
					"action": "bin/dash_on_v5.sh",
					"exitmenu": true
				},
				{
					"name": "关闭仪表盘",
					"action": "bin/dash_off.sh",
					"exitmenu": true
				},
				{
					"name": "电源键探针 Probe6",
					"action": "bin/dash_probe6.sh"
				},
				{
					"name": "能力诊断 Diag",
					"action": "bin/dash_diag.sh"
				}
			]
		}
	]
}
JSON
    mv "$MENU.new" "$MENU" && say "OK  更新 KUAL 菜单"
else
    say "WARN 未找到 $MENU，菜单未更新"
fi

# ---- 5. 自检 ----
say "---- 自检 ----"
for f in dashd_v5.sh dash_on_v5.sh cur_p.png cur_l.png; do
    if [ -s "$DST/$f" ]; then
        say "  $f: $(wc -c < "$DST/$f") bytes"
    else
        say "  $f: 缺失"
    fi
done
[ -s "$EXT/bin/dash_on_v5.sh" ] && say "  KUAL入口: OK" || say "  KUAL入口: 缺失"

# ---- 6. 可选：立刻启动 ----
if [ "$1" = "start" ]; then
    say "---- 立刻启动 ----"
    sh "$EXT/bin/dash_on_v5.sh" 2>&1 | head -5
    sleep 3
    say "守护日志尾部:"
    tail -12 "$DST/dashd.log" 2>/dev/null | sed 's/^/  /'
fi

say "===== 部署完成 ====="
