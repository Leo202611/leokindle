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
#      【2026-11-10 修正】WAKE 不再作为 rtcWakeup 的秒数，仅作闹钟开关；
#      秒数改由 wait_seconds_to_next_slot() 按绝对槽位算（见下方 M6 说明）。
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
SVER="20261110.1"

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
# 【M6 · 2026-11-10】距下一「绝对槽位」的秒数
#   来源：Basti189 bin/scheduler.sh L110-113
#           NEXT_UPDATE_SECONDS = NEXT_UPDATE_MIN * 60
#           WAIT_SECONDS = NEXT_UPDATE_SECONDS - CURRENT_DAY_SECONDS
#         zpetterd kindle/bin/utils.sh L115-127 + scheduler.sh L161-165
#           set_rtc_wakeup "${REMAINING}"，REMAINING = ENDTIME - currentTime
#   lipc rtcWakeup 只收相对秒，但秒数必须由绝对槽位算出：
#     WAIT = (当前槽位编号 + 1) * INTERVAL - 当天已过秒数
#   【为何改】原 fanzhh L106-111 传固定 WAKE（本项目 M5 映射成 1200）：
#     每轮更新完成后才设 1200s，更新耗时约 75s 被逐轮累加 -> 实测周期 1275s，
#     触发点一路后移、:00/:20/:40 槽位被跳过（11-10 12:04/12:26/12:47/13:12 实证）。
#     每轮 readyToSuspend 用挂钟重算，晚几秒下一轮自动归位，漂移不累积。
#   与前台主循环 L246-247 用同一 DAYSEC/INTERVAL 公式，两路判据天然一致。
#   变量加 _WS_ 前缀，避免 ash 全局变量污染主循环（历史教训）。
# ---------------------------------------------------------------------------
wait_seconds_to_next_slot() {
    _WS_HM=$(date +'%H %M %S' 2>/dev/null)
    _WS_H=${_WS_HM%% *}; _WS_REST=${_WS_HM#* }
    _WS_M=${_WS_REST%% *}; _WS_S=${_WS_REST#* }
    _WS_H=${_WS_H#0}; [ -z "$_WS_H" ] && _WS_H=0
    _WS_M=${_WS_M#0}; [ -z "$_WS_M" ] && _WS_M=0
    _WS_S=${_WS_S#0}; [ -z "$_WS_S" ] && _WS_S=0
    _WS_DAYSEC=$(( _WS_H * 3600 + _WS_M * 60 + _WS_S ))
    _WS_SLOT=$(( _WS_DAYSEC / INTERVAL ))
    echo $(( (_WS_SLOT + 1) * INTERVAL - _WS_DAYSEC ))
}

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
                # WAKE 仅作开关（DASH_WAKE_INTERVAL=0 可关闹钟）；真正的秒数
                # 由绝对槽位算出，见 wait_seconds_to_next_slot（Basti189 L110-113）。
                RTC_WAIT=$(wait_seconds_to_next_slot)
                i=0
                while [ "$i" -lt 4 ]; do
                    if lipc-set-prop -i "$POWERD" rtcWakeup "$RTC_WAIT" > /dev/null 2>&1; then
                        log "readyToSuspend：已设置 rtcWakeup=${RTC_WAIT}s（下一绝对槽位）"
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

log "守护启动 v$SVER：刷新间隔 ${INTERVAL}s，闹钟开关=${WAKE}（秒数按绝对槽位重算），无线策略=${WIFI_MODE}，事件监听=${WATCH_OK}"

watch_events &
WATCHER=$!
trap 'kill "$WATCHER" 2> /dev/null' EXIT INT TERM

# 【M6 · 2026-11-09 07:4x 用户选定】把 fanzhh 的「now-last >= INTERVAL」相对间隔
#   判据换成【绝对槽位判据】，来源另外两份已实机验证的 upstream：
#     Basti189 bin/scheduler.sh L85  CURRENT_DAY_SECONDS = H*3600+M*60+S
#     Basti189 bin/scheduler.sh L104-106  COMPLETE_INTERVALS = PERIOD_ELAPSED / INTERVAL
#     zpetterd kindle/bin/scheduler.sh L79-120  get_time_to_next_update（按当天绝对分钟算下个槽位）
#   为何改：fanzhh 相对间隔在每次部署/重启后会重置计时起点（07:36 部署 → 下次 07:56），
#   于是 7:40 槽位被跳过；用户要求每个 :00/:20/:40 都要更新。
#   槽位编号 = 当天绝对秒数 / INTERVAL，边界天然落在本地 :00/:20/:40，
#   与计时起点、重启、部署完全无关。仅改主循环判据这一处，
#   watch_events 后台 / 三段 WiFi 重试 / handle_event / STAMP 写入 全部保持原文不动。
#   注意：STAMP 仍按 fanzhh 原样写 epoch 秒（事件回调 L164 也写它），
#   故主循环判据改用独立的内存变量 last_slot，不把 STAMP 当槽位基准。
#   【配置约束】INTERVAL 必须与 CI 的 SS_SLOT_MINUTES 对齐：当前 1200s ↔ "0 20 40"。
#   若改 INTERVAL，槽位边界会随之改变，须同步改 CI 与设备端 SS_SLOT_MINUTES，
#   否则「判据槽位」与「云端预渲染的槽位图」会错位。
last_slot=-1

while true; do
    load_conf
    HM=$(date +'%H %M %S' 2>/dev/null)
    H=${HM%% *}; REST=${HM#* }; M=${REST%% *}; S=${REST#* }
    H=${H#0}; [ -z "$H" ] && H=0      # 去前导零，避免 ash 把 08/09 当八进制
    M=${M#0}; [ -z "$M" ] && M=0
    S=${S#0}; [ -z "$S" ] && S=0
    DAYSEC=$(( H * 3600 + M * 60 + S ))
    SLOT_NOW=$(( DAYSEC / INTERVAL ))
    if [ "$SLOT_NOW" -ne "$last_slot" ]; then
        log "槽位 $SLOT_NOW 到达（${H}:${M}:${S}），触发更新"
        do_update
        last_slot=$SLOT_NOW
        date +%s > "$STAMP" 2> /dev/null
    fi
    sleep "$POLL"
done
