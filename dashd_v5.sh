#!/bin/sh
# Kindle 日历天气仪表盘 · 守护进程 v3
#
# v3 相对 v2 的改动：
#   1) 删掉 eips 电量叠加（draw_battery / load_batt_pos / fetch_batt_pos）：
#      电量改为云端把「电量：94」整串烧进 PNG，设备端不再写任何 eips 文字。
#      原因：eips 只有字符格坐标、无中文字形，叠加的数字频繁越界或压住画面。
#   2) 删掉 "SYNCING..." 提示：它用 eips 画在右上角，会压住画面内容，
#      而且 e-ink 局部刷新有残影，新图到位后那行字未必能被干净覆盖。
#      改为：画面刷新本身就是反馈（底部「更新 HH:MM」会变）。
#   3) 修实例存活判断：busybox 的 ash 上 `kill -0` 对不存在的 PID 也可能返回成功，
#      改成 [ -d /proc/$PID ] 才准。
#   4) 支持「触发刷新」标记文件：/var/local/dash_refresh，
#      KUAL 里再点一次「启动仪表盘」就会立刻重新取图刷新，而不是只重绘旧缓存图。
#   5) 支持「切换横竖屏」标记文件：/var/local/dash_rotate。
#
# 退出方式：按电源键（见 dashd.sh 里的 power_monitor）/ 短按屏幕任意处
#           / 拔 USB 后在 /mnt/us/dash/ 放 stop 文件 / KUAL「关闭仪表盘」
export PATH=/usr/sbin:/sbin:/usr/bin:/bin:$PATH
export TZ=CST-8

LOG=/mnt/us/dash/dashd.log
# 缓存图按版式分开存。v4 用单一 cur.png，导致：
#   1) 横屏取到的 _land.png 会覆盖竖屏图，下次竖屏启动画出来的是横版内容；
#   2) 设备上那份 cur.png 是 11-03 的旧排版（142px 日号、有遮挡），
#      一启动就画出来，用户第一眼看到的是旧版。
# 现在竖屏用 cur_p.png、横屏用 cur_l.png，各自独立，互不污染。
IMG_P=/mnt/us/dash/cur_p.png
IMG_L=/mnt/us/dash/cur_l.png
PIDF=/var/local/dashd.pid
LAST=""
ORIENT=p                   # p=竖屏 l=横屏
ORIENT_FILE=/mnt/us/dash/orient
REFRESH_FLAG=/var/local/dash_refresh
ROTATE_FLAG=/var/local/dash_rotate
STOP_FLAG=/var/local/dash_stop
# GUI 冻结标记：用了温和方案（只停重绘）时置位，退出时据此恢复。
# 没置位说明 GUI 被整个 stop 了，走 initctl start 拉回。
FROZE_FLAG=/var/local/dash_freeze
GUI_FREEZE="com.lab126.gui.refresh"

BASE_CDN="https://gcore.jsdelivr.net/gh/Leo202611/leokindle@dash"
BASE_PAGES="https://Leo202611.github.io/leokindle"

# ---------- 真实电量上报（A 方案：云端中转）----------
# 矛盾：PNG 是 CI 用 --hours 26 在云端提前批量渲染好的，渲染那一刻
# 并不知道设备当时的电量。所以走「设备每小时上报 -> 云端记录 ->
# CI 下一轮读回并 --batt 注入 -> 设备再取图」的闭环。
#
# 设备读电量本身零成本（Probe5 实测属性真实存在）：
#   lipc-get-prop com.lab126.powerd battLevel   -> 0..100
#   lipc-get-prop com.lab126.powerd isCharging  -> 0/1
#   sysfs 兜底：/sys/class/power_supply/bd7181x_bat/capacity
#
# 中转站选 ntfy.sh：匿名可写可读、无 token 无密钥、消息缓存 12h，
# 正好覆盖每小时一次的节奏。之前验证过的 webhook.site token 只有 ~7 天
# 有效期，写进不易更新的设备脚本会静默失效，故不做主通道。
BATT_TOPIC="k8dash_batt_7f3c9e2a"
BATT_URL="https://ntfy.sh/$BATT_TOPIC"
BATT_LAST=/mnt/us/dash/last_batt.json
# CI 每小时 :17 用最新电量重渲染整套图；:35 再取一次同一小时的图，
# 就能把本小时刚上报的电量显示出来（否则整点那张滞后约 1 小时）。
BATT_FOLLOW_MIN=35
BATT_FOLLOW_H=""           # 已做过跟进取图的小时，防止一小时内重复取图

log() { echo "[$(date +"%m-%d %H:%M:%S")] $*" >> "$LOG"; }

# 读实测电量并上报。上报失败绝不能影响取图与显示：所有 curl 带超时，
# 且调用方不检查返回值。正常证书校验失败时降级 -k 重试一次（老固件 CA 可能过期）。
report_batt() {
    B=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    case "$B" in ''|*[!0-9]*)
        B=$(cat /sys/class/power_supply/bd7181x_bat/capacity 2>/dev/null) ;;
    esac
    case "$B" in ''|*[!0-9]*)
        log "电量上报: 读不到 battLevel / capacity，跳过"
        return 1 ;;
    esac
    if [ "$B" -lt 0 ] 2>/dev/null || [ "$B" -gt 100 ] 2>/dev/null; then
        log "电量上报: 数值越界 [$B]，跳过"
        return 1
    fi
    C=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
    case "$C" in 1) ;; *) C=0 ;; esac
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    PAYLOAD="{\"batt\":$B,\"charging\":$C,\"ts\":\"$TS\"}"
    if curl -s -m 15 -o /dev/null -X POST -H "Content-Type: application/json" \
            --data-binary "$PAYLOAD" "$BATT_URL" 2>>"$LOG" || \
       curl -sk -m 15 -o /dev/null -X POST -H "Content-Type: application/json" \
            --data-binary "$PAYLOAD" "$BATT_URL" 2>>"$LOG"; then
        echo "$PAYLOAD" > "$BATT_LAST" 2>/dev/null
        log "电量上报成功: $PAYLOAD"
        return 0
    fi
    log "电量上报失败（不影响显示）: $PAYLOAD"
    return 1
}

# 当前版式对应的图片路径。ORIENT 变化时必须重新调用，
# 否则横竖屏的取图/绘图会写到同一个文件上。
set_img() {
    if [ "$ORIENT" = "l" ]; then IMG="$IMG_L"; else IMG="$IMG_P"; fi
}

# ---------- 进程存活判断 ----------
# 不要用 `kill -0 $PID`：Kindle 的 busybox/ash 上对不存在的 PID 也可能返回 0，
# 结果就是「其实没实例」却被判成「实例在跑」，刷新逻辑全部失效。
# /proc 是最可靠的判据。
alive() {
    [ -n "$1" ] && [ -d "/proc/$1" ]
}

# ---------- WiFi 按需开关 ----------
# Kindle 从息屏/休眠恢复后，WiFi 重新关联 + DHCP 拿 IP 需要 30~60 秒，
# 原来只等 24 秒就放弃，是"22 点仍显示 21 点"的直接原因。
wifi_on() {
    lipc-set-prop com.lab126.wifid cmState 1 >/dev/null 2>&1
    i=0
    while [ $i -lt 45 ]; do
        sleep 2
        st=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        if [ "$st" = "1" ]; then
            break
        fi
        i=$((i+1))
    done
    # 等 DHCP 拿到 IP
    j=0
    while [ $j -lt 25 ]; do
        ip=$(lipc-get-prop com.lab126.wifid ipv4 2>/dev/null)
        case "$ip" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) sleep 2; return 0 ;;
        esac
        sleep 2
        j=$((j+1))
    done
    log "警告: WiFi 已开但 50 秒内未拿到 DHCP 地址"
    return 0
}

wifi_off() {
    lipc-set-prop com.lab126.wifid cmState 0 >/dev/null 2>&1
}

# ---------- 校时 ----------
sync_clock() {
    if command -v ntpdate >/dev/null 2>&1; then
        ntpdate -u -t 8 pool.ntp.org    >/dev/null 2>&1 && return 0
        ntpdate -u -t 8 ntp.aliyun.com  >/dev/null 2>&1 && return 0
        ntpdate -u -t 8 time.apple.com  >/dev/null 2>&1 && return 0
    fi
    local ms
    ms=$(curl -s -m 10 "http://api.m.taobao.com/rest/api3.do?api=mtop.common.getTimestamp" 2>/dev/null \
        | sed -n 's/.*"t":"\([0-9]*\)".*/\1/p')
    [ -n "$ms" ] && date -s "@$(( ms / 1000 ))" >/dev/null 2>&1 && return 0
    return 1
}

# ---------- 网络整点文件名 ----------
NET_EPOCH=0
NET_TS=0
net_hour_core() { echo "$(( $1 + 28800 ))" | TZ=UTC awk '{print strftime("%Y%m%d_%H", $1)}'; }
hourfile() {
    local now=$(date +%s 2>/dev/null || echo 0)
    if [ "$NET_EPOCH" -ne 0 ] && [ $((now - NET_TS)) -lt 3600 ]; then
        net_hour_core "$NET_EPOCH"; return
    fi
    local ms
    ms=$(curl -s -m 10 "http://api.m.taobao.com/rest/api3.do?api=mtop.common.getTimestamp" 2>/dev/null \
        | sed -n 's/.*"t":"\([0-9]*\)".*/\1/p')
    if [ -n "$ms" ]; then
        NET_EPOCH=$(( ms / 1000 )); NET_TS=$(date +%s 2>/dev/null || echo 0)
        net_hour_core "$NET_EPOCH"; return
    fi
    date +%Y%m%d_%H
}

# ---------- 校验 + 取图 ----------
valid() {
    f="$1"
    sz=$(wc -c < "$f" 2>/dev/null)
    [ "${sz:-0}" -gt 5000 ] 2>/dev/null || return 1
    if head -c 300 "$f" 2>/dev/null | grep -qi "html\|doctype\|not found\|<head\|\"message\""; then
        return 1
    fi
    return 0
}

fetch() {
    h="$1"; fn="$h.png"
    # 目标文件可指定：默认写当前版式的缓存位，特殊场景（横屏回退竖屏图）要指定。
    DST="${2:-$IMG}"
    # 临时文件名带 PID：竖横屏若同时取图，共用 ".tmp" 会互相覆盖。
    TMP="$DST.tmp.$$"
    # 通道1：GitHub API raw —— 永不过期，永远最新（jsDelivr 缓存约 12h）
    if curl -sL -m 20 -H "Accept: application/vnd.github.raw" \
       -o "$TMP" "https://api.github.com/repos/Leo202611/leokindle/contents/$fn?ref=dash"; then
        if valid "$TMP"; then
            mv "$TMP" "$DST"
            log "取图成功: API/$fn ($(wc -c < "$DST") bytes) -> $DST"
            return 0
        fi
        log "取图失败: API/$fn 内容不合法"
    else
        log "取图失败: API/$fn 网络错误"
    fi
    # 通道2/3：jsDelivr 与 Pages
    for b in "$BASE_CDN" "$BASE_PAGES"; do
        if curl -sL -m 40 -o "$TMP" "$b/$fn"; then
            if valid "$TMP"; then
                mv "$TMP" "$DST"
                log "取图成功: $b/$fn ($(wc -c < "$DST") bytes) -> $DST"
                return 0
            fi
        fi
        log "取图失败: $b/$fn"
    done
    rm -f "$TMP"
    return 1
}

# 竖屏 / 横屏两套文件名：横屏图另存为 <hour>_land.png
fetch_one() {
    h="$1"
    if [ "$ORIENT" = "l" ]; then
        fetch "${h}_land" && return 0
        # 横屏图若还没生成，退回竖屏图。
        # 注意：竖屏图要写进 cur_l.png（当前版式的缓存位），
        # 不能直接 mv 到 IMG（那会把竖屏图存成竖屏缓存，版式就错位了）。
        log "横屏图缺失，回退竖屏 $h.png"
        fetch "$h" "$IMG_L"
        return $?
    fi
    fetch "$h" "$IMG_P"
}

refresh_screen() {
    h="$1"
    if fetch_one "$h"; then
        eips -f -g "$IMG" >> "$LOG" 2>&1
        return 0
    fi
    return 1
}

# ---------- 触摸：短按退出 / 长按 3 秒切换横竖屏 ----------
# 事件结构（dash_probe2 已确认）：16 字节/事件
#   type=3 code=0x35(53, X) / 0x36(54, Y)  ABS_MT_POSITION_X / _Y
#   type=1 code=0x14a(330) BTN_TOUCH  value=1 落下 / 0 抬起
#   type=0 code=0 SYN_REPORT
#
# 说明：按电源键也能退出（见 power_monitor），触摸短按是并行的兜底方式，
#       两者都会走同一条退出路径。
touch_monitor() {
    local MAINPID="$1"
    local hex b8 b9 b10 b11 b12 b13 b14 b15 type code value lx=0 ly=0
    local down_t=0 press_x=0 press_y=0 dur
    while :; do
        alive "$MAINPID" || exit 0
        hex=$(dd if=/dev/input/event0 bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
        [ "${#hex}" = "32" ] || continue
        b8=$(printf %s "$hex" | cut -c17-18);  b9=$(printf %s "$hex" | cut -c19-20)
        b10=$(printf %s "$hex" | cut -c21-22); b11=$(printf %s "$hex" | cut -c23-24)
        b12=$(printf %s "$hex" | cut -c25-26); b13=$(printf %s "$hex" | cut -c27-28)
        b14=$(printf %s "$hex" | cut -c29-30); b15=$(printf %s "$hex" | cut -c31-32)
        type=$(( 0x$b8 + 0x$b9 * 256 ))
        code=$(( 0x$b10 + 0x$b11 * 256 ))
        value=$(( 0x$b12 + 0x$b13 * 256 + 0x$b14 * 65536 + 0x$b15 * 16777216 ))
        if [ "$type" = "3" ]; then
            [ "$code" = "53" ] && lx=$value
            [ "$code" = "54" ] && ly=$value
        elif [ "$type" = "1" ] && [ "$code" = "330" ]; then
            if [ "$value" = "1" ]; then
                down_t=$(date +%s)
                press_x=$lx; press_y=$ly
            else
                # 抬起：判断是短按还是长按
                dur=$(( $(date +%s) - down_t ))
                if [ "$dur" -ge 3 ]; then
                    log "长按 ${dur}s，切换横/竖屏"
                    if [ "$ORIENT" = "p" ]; then
                        ORIENT=l; echo l > "$ORIENT_FILE"
                    else
                        ORIENT=p; echo p > "$ORIENT_FILE"
                    fi
                    # 版式变了，当前版式的图片路径也要跟着变。
                    # 少了这一句，切换后仍然往上一个版式的缓存位取图/画图，
                    # 结果是"切了横屏但画出来的还是竖屏那张"。
                    set_img
                    log "版式切换为 $ORIENT，图片路径改为 $IMG"
                    touch "$ROTATE_FLAG"
                else
                    log "短按 (x=$press_x y=$press_y)，退出到阅读器"
                    touch "$STOP_FLAG"
                    lipc-set-prop com.lab126.wifid cmState 1 >/dev/null 2>&1
                    # 统一走 restore_gui（冻结方案下是恢复重绘，退化方案下是拉回 GUI）
                    restore_gui
                    kill "$MAINPID" 2>/dev/null
                    exit 0
                fi
            fi
        fi
    done
}

keep_awake() {
    # ---- 防息屏的三层手段 ----
    # 1) lipc preventScreenSaver：部分固件有效，失败无害。
    #    实测此固件的 com.lab126.powerd 只探到 state/battLevel/isCharging，
    #    preventScreenSaver 大概率不存在，所以这一层通常不生效（属预期，不报错）。
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
    # 2) RTC wakealarm：设置一个 10 分钟后的唤醒闹钟，
    #    让系统不要进入深度休眠。这一层是真正可靠的兜底。
    if [ -e /sys/class/rtc/rtc0/wakealarm ]; then
        echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
        echo $(( $(date +%s) + 600 )) > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
    fi
    # 3) 背光常亮（部分固件有这个节点；没有就跳过）
    if [ -e /sys/devices/backlight/kt3_wled/brightness ]; then
        echo 255 > /sys/devices/backlight/kt3_wled/brightness 2>/dev/null
    fi
    return 0
}

# ---------- 电源键感知 ----------
#
# 实测结论（Probe4/Probe5/Probe6 三轮探针，逐层排查）：
#   1) lipc 这条路走不通。com.lab126.powerd 只有三个属性真实存在：
#      state(=active) / battLevel / isCharging。
#      screenState / powerState / screenOn / suspendState 全部 NoSuchProperty，
#      com.lab126.hal 服务根本不存在，/dev/input 下只有 event0(触摸屏)+mice。
#   2) 电源键在**内核中断**里。Probe6 实测 /proc/interrupts：
#        322:  44   bd7181x  bd7181x-power     ← 电源键所在中断线
#        276:  46   gpio-mxc  bd7181x
#      按一次电源键，322 就 +1（实测 3 次按键 => 44->45->46->47，逐次对应）。
#   3) 内核日志里也有痕迹（dmesg 每次按键打三条）：
#        [29635.130157] Power button pressed, INT_STAT_03 = 0x20   ← 按下
#        [29635.263032] Power button pressed, INT_STAT_03 = 0x10   ← 抬起
#        [29635.268537] Power button pressed, send user event KOBJ_ONLINE
#
# 为什么用 IRQ 计数而不是 dmesg：
#   dmesg 是**环形缓冲区**，会滚动覆盖。Probe6 实测按键日志条数从 36 掉到 31，
#   也就是说仪表盘跑久了，早先的按键日志会被冲掉，dmesg 水位线会"回退"。
#   而 /proc/interrupts 的计数是内核单调递增的累计值，永远不会变小，
#   只要记住启动时的基线值，比较"变大"即可，天然免疫缓冲区滚动。
#
# 短按电源键 = 熄屏（Kindle 自己会回到它的界面），这正好就是"返回"。

# 电源键中断线号（Probe6 实测：bd7181x-power）
POWER_IRQ=322
# 备用：dmesg 关键词（IRQ 读不到时兜底）
POWER_LOG="Power button pressed"

# 读指定中断行的计数；读不到输出空
irq_count() {
    awk -v q="$POWER_IRQ:" '$1==q {print $2; exit}' /proc/interrupts 2>/dev/null
}

# dmesg 兜底：取最后一条电源键日志的内核时间戳
power_stamp() {
    dmesg 2>/dev/null | grep "$POWER_LOG" | tail -1 \
        | sed -n 's/^\[\([0-9.]*\)\].*/\1/p'
}

# 启动时记录基线，并写进日志，方便事后核对固件差异
power_probe() {
    local n=$(irq_count)
    local s=$(power_stamp)
    log "电源键监听: IRQ $POWER_IRQ 基线 = [${n:-读不到}]，dmesg 基线 = [${s:-无}]"
    if [ -z "$n" ]; then
        log "提示: 读不到 IRQ $POWER_IRQ 计数，已降级为 dmesg 监听；短按屏幕退出仍可兜底"
    fi
}

# 监测电源键；检测到即退出到 Kindle 界面
power_monitor() {
    local MAINPID="$1"
    local prev_irq="" prev_stamp="" cur_irq="" cur_stamp=""
    prev_irq=$(irq_count)
    prev_stamp=$(power_stamp)
    while :; do
        alive "$MAINPID" || exit 0
        cur_irq=$(irq_count)
        cur_stamp=$(power_stamp)
        # 主判据：IRQ 计数变大（单调递增，最可靠）
        if [ -n "$cur_irq" ] && [ -n "$prev_irq" ] && [ "$cur_irq" -gt "$prev_irq" ] 2>/dev/null; then
            log "检测到电源键（IRQ $POWER_IRQ: $prev_irq -> $cur_irq），退出仪表盘"
        # 兜底判据：dmesg 水位线变大（IRQ 读不到时用）
        elif [ -z "$cur_irq" ] && [ -n "$cur_stamp" ] && [ -n "$prev_stamp" ] && \
             [ "$(awk -v a="$prev_stamp" -v b="$cur_stamp" 'BEGIN{print (b>a)?1:0}')" = "1" ]; then
            log "检测到电源键（dmesg 水位线 $prev_stamp -> $cur_stamp），退出仪表盘"
        else
            prev_irq="$cur_irq"
            prev_stamp="$cur_stamp"
            sleep 2
            continue
        fi
        touch "$STOP_FLAG"
        lipc-set-prop com.lab126.wifid cmState 1 >/dev/null 2>&1
        # 统一走 restore_gui（冻结方案下是恢复重绘，退化方案下是拉回 GUI）
        restore_gui
        kill "$MAINPID" 2>/dev/null
        exit 0
    done
}

# ---------- 看门狗：主进程没了就重新拉起 ----------
watchdog() {
    local mainpid="$1"
    while :; do
        sleep 45
        if ! alive "$mainpid"; then
            log "看门狗: 主进程 $mainpid 已消失，重新拉起"
            sleep 2
            # 自引用必须指向 v5 自己。原来指向 /mnt/us/dashd.sh（根目录旧版），
            # 一旦主进程被 killall 干掉，看门狗拉起来的是**旧版**，
            # 于是"画面一闪而过"和"电源键不可用"这两个老 bug 全部复活。
            setsid /mnt/us/dash/dashd_v5.sh >> "$LOG" 2>&1 &
            exit 0
        fi
    done
}

# ---- 入口分流 ----
# 带 --watchdog 参数时，本进程只充当看门狗，不进入主循环。
case "$1" in
    --watchdog)
        watchdog "$2"
        exit 0
        ;;
esac

mkdir -p /mnt/us/dash
rm -f /mnt/us/dash/stop "$STOP_FLAG" "$ROTATE_FLAG"
echo $$ > "$PIDF"

# 无论以何种方式退出（正常退出、被 killall 强杀、被短按/电源键），
# 都必须把 GUI 拉回来，否则 Kindle 会黑屏且触摸完全无响应。
# 之前没有这个 trap，killall 掉实例后 GUI 一直是停的，表现就是"点了没反应"。
restore_gui() {
    # 优先恢复被冻结的重绘服务（温和方案，KUAL 一直活着）
    if [ -n "$GUI_FREEZE" ] && [ -f "$FROZE_FLAG" ]; then
        lipc-set-prop "$GUI_FREEZE" state 1 >> "$LOG" 2>&1
        rm -f "$FROZE_FLAG"
        log "已恢复 GUI 重绘服务: $GUI_FREEZE"
        return 0
    fi
    # 退化方案：GUI 被整个停掉了，把它拉回来
    initctl start lab126_gui >> "$LOG" 2>&1 || start lab126_gui >> "$LOG" 2>&1
}
trap 'restore_gui' EXIT
trap 'restore_gui; exit 0' INT TERM

[ -f "$ORIENT_FILE" ] && ORIENT=$(cat "$ORIENT_FILE")
case "$ORIENT" in l|p) ;; *) ORIENT=p ;; esac
set_img

log "===== 守护启动(pid $$) 设备时间: $(date) 版式=$ORIENT 图片=$IMG ====="
power_probe

# 看门狗先起（指向 v5 自己，避免重启后回退到旧版）
setsid /mnt/us/dash/dashd_v5.sh --watchdog $$ >> "$LOG" 2>&1 &

# ---- 关键 1：先让 GUI 让出屏幕，再画图 ----
# lab126_gui 活着的时候，它会周期性重绘屏幕，把我们 eips 画上去的内容覆盖掉。
# 原顺序是「先画图 -> wifi_on(30~90 秒) -> 取图 -> 最后才停 GUI」，
# 这整段时间 GUI 都活着，用户看到的现象就是"画面一闪而过"，
# 然后黑屏/图书馆界面。（实测 07:53 的日志：画完缓存图后卡在 wifi_on，画面就没了。）
#
# 但**不能直接 initctl stop lab126_gui**：
#   KUAL 菜单本身就是 lab126_gui 的一部分，停掉它 =
#   菜单消失 + 触摸完全失灵 + 只能拔电源重启才能恢复
#   （这正是用户反馈的"退出后只有拔电源才能重新加载 kindle"）。
#
# 正确做法是「冻结」而不是「杀死」：
#   把 GUI 的_refresh_ 定时任务停掉（停掉重绘，但进程还在，
#   KUAL 菜单和触摸服务仍然活着），画完图再恢复。
# 若这个服务不存在，退而求其次用 stop/start（restore_gui 负责拉回）。
#
# 先试温和方案：
GUI_FREEZE="com.lab126.gui.refresh"
if lipc-get-prop "$GUI_FREEZE" state >/dev/null 2>&1; then
    lipc-set-prop "$GUI_FREEZE" state 0 >> "$LOG" 2>&1
    touch "$FROZE_FLAG"
    log "已冻结 GUI 重绘服务: $GUI_FREEZE"
else
    log "无 $GUI_FREEZE 服务，改用 stop/start 方式"
    initctl stop lab126_gui >> "$LOG" 2>&1 || stop lab126_gui >> "$LOG" 2>&1
fi
sleep 1

# 防息屏要提前：下面 wifi_on 最长要等 90 秒，
# 若期间 Kindle 自动息屏，用户会以为"画面闪了一下就没了"。
# keep_awake 用 lipc 的 preventScreenSaver 属性；实测该属性在部分固件上
# 不存在（Probe5 只探到 state/battLevel/isCharging），失败也无所谓，
# 下面的 rtc wakealarm 与定期补绘才是真正兜底。
keep_awake

# ---- 关键 2：先把缓存画面立刻画出来，绝不让用户对着空白屏等 90~140 秒 ----
# 原逻辑先等 WiFi + 取图才画图，导致"点了没反应"；
# 用户等不及反复点击 -> dash_on.sh 的 killall 杀掉正在取图的实例 -> 永远出不来画面。
if [ -s "$IMG" ]; then
    eips -f -g "$IMG" >> "$LOG" 2>&1
    log "已立即绘制缓存画面: $IMG"
else
    log "无缓存图（$IMG 不存在），只能等网络取图"
fi

wifi_on
sync_clock && log "校时完成: $(date)" || log "校时失败，依赖本地时钟"
keep_awake

h=$(hourfile)
log "目标小时: $h"
if refresh_screen "$h"; then
    LAST=$h; log "首屏完成 $h"
else
    sleep 20; wifi_on; refresh_screen "$h" && LAST=$h || log "首屏取图失败，将沿用旧图"
fi

# 补绘两遍：e-ink 局部刷新有残影，且取图期间可能有过渡帧
sleep 3
eips -f -g "$IMG" >> "$LOG" 2>&1
sleep 6
eips -f -g "$IMG" >> "$LOG" 2>&1
log "首屏绘制+补绘完成，关闭 WiFi 进入低功耗循环"
# 启动时补报一次电量：画面已经画好了，此处耗时不影响用户看到首屏。
report_batt
wifi_off

# 启动触摸监听与电源键监听（GUI 已停，此时本进程是触摸的唯一读者）
touch_monitor $$ &
power_monitor $$ &

while :; do
    [ -f "$STOP_FLAG" ] && break
    [ -f /mnt/us/dash/stop ] && log "收到 USB 端退出信号" && break
    sleep 10
    [ -f "$STOP_FLAG" ] && break
    [ -f /mnt/us/dash/stop ] && log "收到 USB 端退出信号" && break

    # 用户长按切换了版式：立刻重取对应图
    if [ -f "$ROTATE_FLAG" ]; then
        rm -f "$ROTATE_FLAG"
        log "版式切换为 $ORIENT，立即重取"
        wifi_on; sync_clock >/dev/null 2>&1
        report_batt
        h=$(hourfile)
        refresh_screen "$h" && LAST=$h
        wifi_off
        continue
    fi

    # KUAL 里再点了一次「启动仪表盘」：立刻重新取图刷新
    if [ -f "$REFRESH_FLAG" ]; then
        rm -f "$REFRESH_FLAG"
        log "收到刷新请求，立即重取"
        wifi_on; sync_clock >/dev/null 2>&1
        report_batt
        h=$(hourfile)
        if refresh_screen "$h"; then
            LAST=$h; log "已刷新 -> $h"
        else
            log "刷新失败($h)，保留上一张 $LAST"
        fi
        wifi_off
        continue
    fi

    keep_awake
    hd=$(date +%Y%m%d_%H)

    # ---- 电量跟进取图 ----
    # 整点取到的那张图是上一轮 CI（上小时 :17）渲染的，电量滞后约 1 小时。
    # CI 在本小时 :17 已用刚上报的电量重渲染整套图，所以到 :35 再取一次
    # **同一个小时**的图，就能把本小时实测电量显示出来。
    # 三重保险：只在已成功画过图（LAST 非空）、当前小时与 LAST 一致、
    # 且本小时尚未跟过时执行；一小时最多一次，失败也不影响现有画面。
    # ${mm#0} 去掉前导零，避免 ash 把 "08"/"09" 当八进制解析报错。
    mm=$(date +%M); mm=${mm#0}; [ -z "$mm" ] && mm=0
    if [ -n "$LAST" ] && [ "$hd" = "$LAST" ] && \
       [ "$BATT_FOLLOW_H" != "$hd" ] && \
       [ "$mm" -ge "$BATT_FOLLOW_MIN" ] 2>/dev/null; then
        BATT_FOLLOW_H="$hd"
        log "电量跟进: :$mm 重取 $LAST（CI 应已按最新电量重渲染）"
        wifi_on
        report_batt
        refresh_screen "$LAST" || log "电量跟进取图失败，保留当前画面"
        wifi_off
        continue
    fi

    [ "$hd" = "$LAST" ] && continue
    wifi_on
    sync_clock >/dev/null 2>&1
    # 整点这一报最关键：CI :17 读到的就是它。
    report_batt
    h=$(hourfile)
    if refresh_screen "$h"; then
        LAST=$h; log "已刷新 -> $h"
    else
        log "刷新失败($h)，保留上一张 $LAST；5 秒后重试一轮"
        sleep 5
        refresh_screen "$h" && LAST=$h
    fi
    wifi_off
    log "WiFi 已关闭"
done

log "===== 守护退出 ====="
rm -f "$STOP_FLAG" /mnt/us/dash/stop "$PIDF"
wifi_on
# 退出时统一走 restore_gui：
#   温和方案下它是"恢复 GUI 重绘服务"；
#   退化方案下它是"把整个 lab126_gui 拉回来"。
# 不再在这里单独 initctl start，否则会和 restore_gui 重复动作。
restore_gui
log "已恢复 Kindle 界面"
