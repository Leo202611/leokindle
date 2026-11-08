#!/bin/sh
# ---------------------------------------------------------------------------
# 待机画面调度器 —— 逐行移植 fanzhh/kindle-calendar-weather 的 dash-daemon.sh
# （main 分支 L1-212，Kindle 7 / 5.11.1.1 实机验证「每小时真深睡唤醒」的那份）
#
# 【2026-11-09 02:0x 减法重写】此前本项目在这份实现外层层加自创机制，
#   11/8–11/9 连续失败（sysfs wakealarm、-s 单发循环、漏抄前台主循环、
#   mkdir 互斥锁、60s 时间戳去重、deferSuspend、启动兜底设闹钟），
#   全部删除，回到 upstream 原版。以后改本文件先回答：
#   「这一行在 fanzhh 源码第几行？」答不出就不要加。
#
# 只做 5 处不可避免的映射，其余逐行对应原文：
#   M1 原 L127/141/154/207 /mnt/us/documents/ss-install.sh
#      → 本项目 $RUN_DIR/ss_update_once.sh（拉图+刷屏+写 linkss 的脚本）
#   M2 原 L30 IMG=/mnt/us/screensaver-backup/.current.png
#      → /mnt/us/linkss/screensavers/bg_ss00.png（本项目屏保落盘路径）
#   M3 原 L29 STAMP=/mnt/us/.dash_last_check / L31 LOG=/mnt/us/dash.log
#      → /mnt/us/dash/ 目录下（本项目文件布局）
#   M4 原 L61-64 net_probe 探测自建服务器 http://$HOSTPORT/health
#      → lipc-get-prop com.lab126.wifid cmState = CONNECTED
#        （本项目无常开服务器；用设备原生属性判断 WiFi 就绪，语义等价、零网络 I/O）
#   M5 原 L18-19 DASH_INTERVAL=1800 / DASH_WAKE_INTERVAL=3600
#      → 1200 / 1200（用户 11/9 定案「每 20 分钟」）。仍可由 $CONF 覆盖。
#
# 【保留原版的关键结论，勿改】
#   * 原 L9-11：直接写 /sys/class/rtc/rtc0/wakealarm 不会唤醒，
#     powerd 休眠末段会用 rtcWakeup 覆盖它。设闹钟只用 lipc rtcWakeup <相对秒>。
#   * 原 L14：readyToSuspend 连发 7 次，回调必须极轻，不做防抖、每轮必设。
#   * 原 L175-183：-m 常驻 + 管道 while read + 外层 while true 断线重连。
#   * 原 L196-212：后台 watch_events & ＋ 前台主循环每 60s 用挂钟 date +%s
#     独立判到点更新。**前台挂钟轮询是「到点必更新」的保障，不得删除**。
#   * 原 L200-209：last 是内存变量，触发后立刻推进；STAMP 只用于重启后初始化。
#   * 全程无任何互斥锁、无 deferSuspend、无事件回调里的网络上报。
# ---------------------------------------------------------------------------
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PATH

# 版本号：仅用于 deploy_v5.sh 自证遥测确认设备上跑的是哪一版（分发链路，非调度机制）
SVER="20261109.5"

CONF=/mnt/us/dash/ss_dash.conf          # M3/M5：可选，改频率不必改脚本
POLL=60
STAMP=/mnt/us/dash/ss_last_check        # M3
IMG=/mnt/us/linkss/screensavers/bg_ss00.png   # M2
LOG=/mnt/us/dash/ss.log                 # M3
POWERD=com.lab126.powerd
EVENTS="goingToScreenSaver,wakeupFromSuspend,readyToSuspend"
RUN_DIR=/tmp/dashss                     # M1：ss_enable.sh 把脚本复制进 tmpfs
[ -f "$RUN_DIR/ss_update_once.sh" ] || RUN_DIR=/mnt/us/dash

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2> /dev/null; }

# ---- 原 L37-54 ----
load_conf() {
    INTERVAL=1200      # M5：原 1800（30 分钟）→ 20 分钟
    WAKE=1200          # M5：原 3600（1 小时）→ 20 分钟
    WIFI_MODE=auto
    if [ -r "$CONF" ]; then
        eval "$(tr -d '\r' < "$CONF")"
        INTERVAL="${DASH_INTERVAL:-1200}"
        WAKE="${DASH_WAKE_INTERVAL:-1200}"
        WIFI_MODE="${DASH_WIFI:-auto}"
    fi
    case "$INTERVAL" in '' | *[!0-9]*) INTERVAL=1200 ;; esac
    case "$WAKE" in '' | *[!0-9]*) WAKE=0 ;; esac
    [ "$INTERVAL" -lt 300 ] && INTERVAL=300
    [ "$WAKE" -gt 0 ] && [ "$WAKE" -lt 120 ] && WAKE=120
}

load_conf

# ---------------------------------------------------------------------------
# 网络诊断 —— 原 L58-83
# ---------------------------------------------------------------------------
# M4：原版 curl /health 探自建服务器；本项目无常开服务器，改用设备原生属性。
net_probe() {
    command -v lipc-get-prop > /dev/null 2>&1 || return 1
    [ "$(lipc-get-prop com.lab126.wifid cmState 2> /dev/null)" = "CONNECTED" ]
}

wifi_switch() {
    lipc-get-prop com.lab126.cmd wirelessEnable 2> /dev/null | tr -d '\r\n'
}

wifi_ip() {
    out=$(ifconfig wlan0 2> /dev/null | grep -i "inet" | head -1)
    [ -z "$out" ] && out=$(ip -4 addr show wlan0 2> /dev/null | grep -i "inet " | head -1)
    echo "$out" | sed 's/^ *//' | cut -c1-60
}

# 一行日志说明当前网络状态：开关 / IP / 默认路由
net_dump() {
    wl=$(wifi_switch)
    ipa=$(wifi_ip)
    rt=$(awk 'NR>1 && $2=="00000000" {print "有"} NR>1 && $2!="00000000" {n=1} END {if (n && !found) print ""}' /proc/net/route 2> /dev/null | head -1)
    [ -z "$rt" ] && rt="无"
    log "$1：无线=${wl:-?} IP=${ipa:-无} 默认路由=${rt}"
}

# ---- 原 L127/141/154/207 的等价物：本项目唯一的「拉图+刷屏」入口 ----
do_update() {
    /bin/sh "$RUN_DIR/ss_update_once.sh" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 事件处理 —— 原 L85-173
# ---------------------------------------------------------------------------
handle_event() {
    line="$1"
    load_conf          # 允许改完 conf 后不重启进程也生效

    case "$line" in
        readyToSuspend*)
            if [ "$WAKE" -gt 0 ]; then
                i=0
                while [ "$i" -lt 4 ]; do
                    if lipc-set-prop -i "$POWERD" rtcWakeup "$WAKE" > /dev/null 2>&1; then
                        log "readyToSuspend：已设置 rtcWakeup=${WAKE}s"
                        break
                    fi
                    i=$((i + 1))
                    sleep 1
                done
                [ "$i" -ge 4 ] && log "readyToSuspend：设置 rtcWakeup 失败"
            fi
            if [ "$WIFI_MODE" = "auto" ]; then
                net_dump "休眠前"
                lipc-set-prop com.lab126.cmd wirelessEnable 0 > /dev/null 2>&1
                sleep 2
                net_dump "关无线后"
            fi
            ;;

        wakeupFromSuspend*)
            log "wakeupFromSuspend：开始更新"
            net_dump "唤醒瞬间"

            ok=0

            # ---- 策略 1：直接开无线 ----
            lipc-set-prop com.lab126.cmd wirelessEnable 1 > /dev/null 2>&1
            sleep 15
            net_dump "策略1后"
            probe=$(net_probe && echo OK || echo FAIL)
            log "策略1：探测=$probe"
            if [ "$probe" = "OK" ]; then
                do_update && { ok=1; log "策略1成功"; }
            fi

            # ---- 策略 2：关掉再打开 ----
            if [ "$ok" = "0" ]; then
                log "策略2：切换无线 0→1"
                lipc-set-prop com.lab126.cmd wirelessEnable 0 > /dev/null 2>&1
                sleep 5
                lipc-set-prop com.lab126.cmd wirelessEnable 1 > /dev/null 2>&1
                sleep 25
                net_dump "策略2后"
                probe=$(net_probe && echo OK || echo FAIL)
                log "策略2：探测=$probe"
                if [ "$probe" = "OK" ]; then
                    do_update && { ok=1; log "策略2成功"; }
                fi
            fi

            # ---- 策略 3：继续等，最多 150 秒 ----
            if [ "$ok" = "0" ]; then
                i=0
                while [ "$i" -lt 10 ]; do
                    i=$((i + 1))
                    sleep 15
                    probe=$(net_probe && echo OK || echo FAIL)
                    log "策略3：第 $i 次探测=$probe"
                    if [ "$probe" = "OK" ]; then
                        do_update && { ok=1; log "策略3成功（第 $i 次）"; }
                        break
                    fi
                done
                [ "$ok" = "0" ] && net_dump "策略3结束"
            fi

            [ "$ok" = "0" ] && log "三种策略都没连上网络"

            last=$(date +%s 2> /dev/null || echo 0)
            [ "$last" -gt 0 ] && date +%s > "$STAMP" 2> /dev/null
            [ -f "$IMG" ] && eips -g "$IMG" > /dev/null 2>&1
            log "wakeupFromSuspend：结束（ok=$ok）"
            ;;

        goingToScreenSaver*)
            log "goingToScreenSaver"
            ;;
    esac
}

watch_events() {
    while true; do
        lipc-wait-event -m "$POWERD" "$EVENTS" 2> /dev/null \
            | while read -r line; do
                [ -n "$line" ] && handle_event "$line"
            done
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# 启动 —— 原 L185-212
# ---------------------------------------------------------------------------
if command -v lipc-wait-event > /dev/null 2>&1; then
    WATCH_OK="是"
else
    WATCH_OK="否"
fi

log "守护启动 v$SVER：刷新间隔 ${INTERVAL}s，唤醒间隔 ${WAKE}s，无线策略=${WIFI_MODE}，事件监听=${WATCH_OK}"

watch_events &
WATCHER=$!
trap 'kill "$WATCHER" 2> /dev/null' EXIT INT TERM

last=$(cat "$STAMP" 2> /dev/null || echo 0)
case "$last" in '' | *[!0-9]*) last=0 ;; esac

while true; do
    load_conf
    now=$(date +%s 2> /dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ $((now - last)) -ge "$INTERVAL" ]; then
        do_update
        last=$(date +%s 2> /dev/null || echo "$now")
        date +%s > "$STAMP" 2> /dev/null
    fi
    sleep "$POLL"
done
