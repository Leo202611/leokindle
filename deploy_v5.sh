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
#   /mnt/us/dash/ss_config.sh          待机画面定时更新 · 配置（可配 SS_HOURS）
#   /mnt/us/dash/ss_update_once.sh     单次换图（KUAL「立即更新」+ 调度器共用）
#   /mnt/us/dash/ss_scheduler.sh       RTC 事件驱动调度器
#   /mnt/us/dash/ss_enable.sh          启用自启 + 停常亮守护 + 立即刷一次
#   /mnt/us/dash/ss_disable.sh         停用自启 + 清 RTC 闹钟
#   /mnt/us/extensions/dash/bin/*.sh   KUAL 入口（由上面拷贝）
#   /mnt/us/extensions/dash/menu.json  菜单（本地生成，不依赖设备上任何遗留文件）
#
# 【2026-11-05 更新】用户定案：待机画面每小时（0–23 共 24 次）更新，
# 设备真正休眠（RTC 唤醒），不再跑常亮仪表盘守护进程。两组菜单互斥，
# 启用屏保定时更新会自动停掉 dashd，否则 keep_awake 会让屏保永远不出现。
# 云端对应产物是 dash 分支的固定槽位图 ss_00..ss_23.png + ss_latest.png。
#
# 电量链路 2026-11-07 恢复为「搭车上报」（用户定案）：
#   ss_update_once.sh 的 report_batt() 在每次整点取图时复用已开的 WiFi
#   顺手 POST 一条电量到 ntfy（单次短超时、失败不重试、零额外唤醒）；
#   CI 读回后把「电量 N%」烧进 PNG 底栏中央。设 SS_BATT_REPORT=0 可随时关掉。
# 旧守护脚本 dashd_v5.sh 的 BATT_REPORT 仍为 0（常亮仪表盘模式，与屏保二选一）。
# 因此本安装器下发的 ss_update_once.sh 必须是最新版，旧版不会上报电量。
# 覆盖采用 mv（替换目录项），正在运行的旧实例仍持旧 inode，不会读坏脚本。
#
# 电脑端服务：wifi_srv/ 目录 + python3 -m http.server 8899
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

# 服务器地址解析：Mac 在家用 WiFi 上 DHCP 可能换 IP，单一硬编码 IP 一旦失效就会静默
# 回退 GitHub 且常被 CDN 缓存旧版，导致「改了半天没部署上去」。改为候选清单探测：
# 先试上次成功的 IP（last_srv），再试当前已知 IP，第一个可达即用，并把成功 IP 记回。
SRV="${DASH_SRV:-}"
if [ -z "$SRV" ]; then
    LAST_SRV=$(cat /mnt/us/dash/last_srv 2>/dev/null)
    for c in $LAST_SRV 192.168.110.57 192.168.110.46; do
        [ -z "$c" ] && continue
        if curl -sL -m 3 -o /dev/null "http://$c:8899/deploy_v5.sh" 2>/dev/null; then
            SRV="$c:8899"; echo "$c" > /mnt/us/dash/last_srv 2>/dev/null; break
        fi
    done
    [ -z "$SRV" ] && SRV="${LAST_SRV:-192.168.110.57}:8899"
fi
GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
LOG=/mnt/us/dash/deploy_v5.log
DST=/mnt/us/dash
EXT=/mnt/us/extensions/dash

say() {
    echo "$*" >> "$LOG" 2>/dev/null
    echo "$*"
}

# 部署自证遥测（2026-11-08）：把「设备到底拉到了哪一版」上报 ntfy，彻底消除
# 「改了半天其实没部署上去 / GitHub CDN 缓存旧版」的盲区。复用电量上报同款 ntfy POST
# 通道（已验证可达），最好努力、失败静默。
DEPLOY_VER="20261109.6"
DEPLOY_TOPIC="k8dash_deploy_4f2a"
dep_report() {
    curl -sL -k -m 5 -X POST -H "Title: deploy" --data-binary "$1" "https://ntfy.sh/$DEPLOY_TOPIC" >/dev/null 2>&1
}

# 脚本类文件：必须全部经 WiFi 下发，一个都不能依赖 USB 预置
# ss_*.sh 是「待机画面定时更新」(每整点)：RTC 唤醒 + 单次换图 + 重新休眠，
# 取代常亮仪表盘守护进程成为主线。ss_config.local 若存在则绝不覆盖（本地改频率用）。
SH_FILES="dashd_v5.sh dash_on_v5.sh dash_on_land.sh dash_on_port.sh dash_off.sh dash_update.sh install_screensaver.sh ss_config.sh ss_update_once.sh ss_scheduler.sh ss_enable.sh ss_disable.sh ss_rtc.sh ss_dance.sh ss_snap.sh"
# 其中需要装进 KUAL bin/ 的入口
ENTRIES="dash_on_v5.sh dash_on_land.sh dash_on_port.sh dash_off.sh dash_update.sh install_screensaver.sh ss_update_once.sh ss_enable.sh ss_disable.sh ss_rtc.sh ss_dance.sh"

mkdir -p "$DST" "$EXT/bin" 2>/dev/null
: > "$LOG" 2>/dev/null
say "===== v5 纯 WiFi 安装 ====="

# ---- 0. 一次性紧急止损（2026-11-05 07:44）----
# 装了带 sysfs wakealarm 的版本后设备不定时自我重启；频繁异常重启还可能让
# /mnt/us 的 FAT 目录项回滚，KUAL 菜单被打回 19:07 之前的原始 6 项
# （那套里连「在线更新(WiFi)」都没有，更没有「停用定时更新」）。
# 所以：只要用户还能点到任意版本菜单里的「在线更新(WiFi)」，本次安装就
# 先把定时服务彻底停掉，再重写 9 项菜单，让设备先稳定下来。
# 用 ss_emergency_done 保证只执行一次：用户之后手动点第 1 项启用时，
# ss_enable.sh 会删掉 ss_no_auto，后续在线更新即恢复正常行为。
if [ ! -f "$DST/ss_emergency_done" ]; then
    say "!! 一次性紧急止损：停用 dashss 定时服务"
    stop dashss >/dev/null 2>&1
    pkill -f 'ss_scheduler.sh' 2>/dev/null
    pkill -f 'ss_update_once.sh' 2>/dev/null
    # 顺手清掉常亮守护残留：否则 dash_update.sh 收尾看到旧 pid 可能又
    # 拉起 keep_awake，设备不休眠、白白耗电。
    pkill -f 'dashd.*\.sh' 2>/dev/null
    rm -f /var/local/dashd.pid /var/local/dash_stop 2>/dev/null
    mntroot rw >/dev/null 2>&1
    rm -f /etc/upstart/dashss.conf 2>/dev/null
    mntroot ro >/dev/null 2>&1
    echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
    rm -f "$DST/ss_enabled" /tmp/dashss.conf 2>/dev/null
    rm -rf /tmp/dashss 2>/dev/null
    echo "stopped $(date)" > "$DST/ss_no_auto" 2>/dev/null
    echo "done $(date)" > "$DST/ss_emergency_done" 2>/dev/null
    say "!! 已停服务 / 删开机自启 / 清 RTC 闹钟；本次不会自动启用"
else
    say "紧急止损已执行过，按正常流程安装"
fi
say "时刻: $(date)"
say "源: http://$SRV  (回退: GitHub main/dash)"

# 电脑 HTTP 只在真的可达时才用：Mac 与 Kindle 常不在同一 WiFi，
# 否则 12 个脚本每个都要白等 30s，「在线更新」会卡好几分钟。
SRV_OK=0
if curl -sL -m 3 -o /dev/null "http://$SRV/deploy_v5.sh" 2>/dev/null; then
    SRV_OK=1
    say "电脑 HTTP 可达，优先本地"
else
    say "电脑 HTTP 不可达，全部走 GitHub（避免逐文件超时）"
fi

# ---- 通用校验 ----
# od 各版本分隔符可能是一格或两格空格，去空格后比十六进制串才可靠
png_ok() { [ "$(head -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; }

gh_raw() {
    # $1=文件名 $2=分支 $3=输出路径
    # -k：Kindle 8 固件 CA 证书较旧，HTTPS 常失败；这里只取公开静态文件，无密钥。
    curl -sLk -m 40 -H "Accept: application/vnd.github.raw" \
         -o "$3" "$GH_API/$1?ref=$2" 2>/dev/null
}

# ---- 1. 拉脚本（电脑 HTTP -> GitHub main）----
pull_sh() {
    f="$1"
    if [ "$SRV_OK" = "1" ] && curl -sL -m 30 -o "$DST/$f.tmp" "http://$SRV/$f" 2>/dev/null; then
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

# 部署自证：上报 SRV_OK 与关键脚本是否含新版 SVER（设备到底拉到没有，一目了然）
dep_report "deploy v$DEPLOY_VER SRV_OK=$SRV_OK updSVER=$(grep -c 'SVER=\"20261109.6\"' "$DST/ss_update_once.sh" 2>/dev/null) schedSVER=$(grep -c 'SVER=\"20261109.5\"' "$DST/ss_scheduler.sh" 2>/dev/null) wifiToggle=$(grep -c 'wirelessEnable 0' "$DST/ss_config.sh" 2>/dev/null)"

# ---- 1.5 【关键动作前置 · 2026-11-09 01:4x】----
# 01:39 那次在线更新卡在后面第 2 步的 GitHub HTTPS 拉图（curl -m 40），
# 只有 "deploy v..." 没有 "deploy DONE"，末尾 6.5 的 ss_enable.sh quick 从未执行：
# 新版 ss_scheduler.sh 虽已下载到 /mnt/us/dash，/tmp/dashss 里跑的仍是旧实例，
# 01:40 槽位因此没更新。故把「启用 + 完成自证」提到任何可选拉图之前，
# 保证关键动作不被后续网络步骤拖死。
# 注意：此处用 $DST/ss_enable.sh（刚拉下来的），不依赖后面第 3 步才写的 $EXT/bin。
case "$1" in start|land|port) DEP_BOOT="$1" ;; *) DEP_BOOT="" ;; esac
if [ -z "$DEP_BOOT" ] && [ -f "$DST/ss_enable.sh" ] && [ ! -f "$DST/ss_no_auto" ]; then
    sh "$DST/ss_enable.sh" quick >> "$LOG" 2>&1
    EARLY_ENABLED=1
    dep_report "deploy DONE v$DEPLOY_VER EARLY schedSVER=$(grep -c 'SVER=\"20261109.5\"' "$DST/ss_scheduler.sh" 2>/dev/null) enabled=$([ -f "$DST/ss_enabled" ] && echo yes || echo no)"
else
    EARLY_ENABLED=0
fi

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
    if [ "$SRV_OK" = "1" ] && curl -sL -m 40 -o "$dst.tmp" "http://$SRV/$dst" 2>/dev/null; then
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

# ---- 2.5 屏保底图（linkss 格式：bg_ss00.png, 600x800 8位灰度）----
# 优先取云端 ss_latest.png。它的语义是「最近一次已发生的更新槽位」画面
# （20:58 时应显示 18:00 那张），不是当前小时实时图；这样也避免把
# 中午 12:00 生成的静态图当屏保装进去。
# 顺序：GitHub/dash ss_latest -> 电脑 HTTP -> GitHub/main 静态兜底。
SS_OK=0
if gh_raw "ss_latest.png" dash "$DST/bg_ss00.png.tmp" \
   && [ -s "$DST/bg_ss00.png.tmp" ] && png_ok "$DST/bg_ss00.png.tmp"; then
    mv "$DST/bg_ss00.png.tmp" "$DST/bg_ss00.png"
    say "OK  bg_ss00.png (GitHub/dash ss_latest, $(wc -c < "$DST/bg_ss00.png") bytes)"
    SS_OK=1
fi
if [ "$SS_OK" != "1" ] && [ "$SRV_OK" = "1" ] && curl -sL -m 20 -o "$DST/bg_ss00.png.tmp" \
        "http://$SRV/bg_ss00.png" 2>/dev/null \
   && [ -s "$DST/bg_ss00.png.tmp" ] && png_ok "$DST/bg_ss00.png.tmp"; then
    mv "$DST/bg_ss00.png.tmp" "$DST/bg_ss00.png"
    say "OK  bg_ss00.png (电脑 HTTP, $(wc -c < "$DST/bg_ss00.png") bytes)"
    SS_OK=1
fi
if [ "$SS_OK" != "1" ] && gh_raw "bg_ss00.png" main "$DST/bg_ss00.png.tmp" \
   && [ -s "$DST/bg_ss00.png.tmp" ] && png_ok "$DST/bg_ss00.png.tmp"; then
    mv "$DST/bg_ss00.png.tmp" "$DST/bg_ss00.png"
    say "OK  bg_ss00.png (GitHub/main 静态兜底)"
    SS_OK=1
fi
if [ "$SS_OK" != "1" ]; then
    rm -f "$DST/bg_ss00.png.tmp"
    say "WARN bg_ss00.png 未取到（不影响定时更新，仅首次设屏保的底图暂缺）"
fi

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
# 【2026-11-04 20:21】用户反馈「没看到启用定时更新」。原因之一是把菜单
# 拆成了两个分组，需要再点进子菜单才看得到。这里改回用户熟悉的**单一分组**，
# 9 项全部平铺，「启用定时更新」排第一，打开 KUAL 就能看到。
# 「在线更新(WiFi)」是长期自举钩子：旧菜单里本来就有这一项，点它即可拉到本菜单。
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
					"name": "1 启用定时更新(每整点)",
					"action": "bin/ss_enable.sh",
					"exitmenu": true
				},
				{
					"name": "2 立即更新待机画面(WiFi)",
					"action": "bin/ss_update_once.sh",
					"exitmenu": true
				},
				{
					"name": "3 停用定时更新",
					"action": "bin/ss_disable.sh",
					"exitmenu": true
				},
				{
					"name": "4 设为屏保(装 linkss 后)",
					"action": "bin/install_screensaver.sh",
					"exitmenu": true
				},
				{
					"name": "5 在线更新(WiFi) - 拉新菜单",
					"action": "bin/dash_update.sh",
					"exitmenu": true
				},
				{
					"name": "6 关闭仪表盘(屏保模式)",
					"action": "bin/dash_off.sh",
					"exitmenu": true
				},
				{
					"name": "7 启动常亮仪表盘(与屏保二选一)",
					"action": "bin/dash_on_v5.sh",
					"exitmenu": true
				},
				{
					"name": "8 切换为横屏",
					"action": "bin/dash_on_land.sh",
					"exitmenu": true
				},
				{
					"name": "9 切换为竖屏",
					"action": "bin/dash_on_port.sh",
					"exitmenu": true
				},
				{
					"name": "10 阶段2深睡:开(RTC省电)",
					"action": "bin/ss_rtc.sh 1",
					"exitmenu": true
				},
				{
					"name": "11 阶段2深睡:关(回阶段1)",
					"action": "bin/ss_rtc.sh 0",
					"exitmenu": true
				},
				{
					"name": "12 阶段2 WiFi dance:开(默认,恢复用)",
					"action": "bin/ss_dance.sh 1",
					"exitmenu": true
				},
				{
					"name": "13 阶段2 WiFi dance:关(不推荐,会不更新)",
					"action": "bin/ss_dance.sh 0",
					"exitmenu": true
				},
				{
					"name": "14 上传屏保图(文件·免拍照)",
					"action": "bin/ss_snap.sh",
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
for f in $SH_FILES cur_p.png cur_l.png bg_ss00.png; do
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

# ---- 6.5 自动启用待机画面定时更新（仅「只安装不启动」时）----
# 用户只有 KUAL 菜单，且设备上那份 19:07 的旧菜单里没有 ss_*.sh 的入口，
# 容易出现「在线更新点过了，却找不到启用定时更新」。这里让「在线更新(WiFi)」
# 点一次就把屏保定时链路装好并拉起；菜单更新后用户再打开即可看到新项。
# 不想自动启用：在设备上建一个空文件 /mnt/us/dash/ss_no_auto 即可。
if [ "${EARLY_ENABLED:-0}" != "1" ] && [ -z "$BOOT" ] && [ -f "$EXT/bin/ss_enable.sh" ] && [ ! -f "$DST/ss_no_auto" ]; then
    # 仅当 1.5 的前置启用没跑成时才走这里（兜底）。正常情况已在拉完脚本后启用完毕。
    say "---- 兜底启用待机画面定时更新 ----"
    sh "$EXT/bin/ss_enable.sh" quick >> "$LOG" 2>&1
    if [ -f "$DST/ss_enabled" ]; then
        say "OK 已自动启用（服务 dashss）；想取消自动启用可建 $DST/ss_no_auto"
    else
        say "WARN 自动启用未完成，请手动点菜单第 1 项「启用定时更新」"
    fi
fi

# TAIL ≠ DONE：DONE 在 1.5 前置启用后立即发出；TAIL 表示脚本一路跑到了末尾。
dep_report "deploy TAIL v$DEPLOY_VER updSVER=$(grep -c 'SVER=\"20261109.6\"' "$DST/ss_update_once.sh" 2>/dev/null) schedSVER=$(grep -c 'SVER=\"20261109.5\"' "$DST/ss_scheduler.sh" 2>/dev/null) early=${EARLY_ENABLED:-0}"
say "===== 安装完成（全程 WiFi，未使用 USB）====="
