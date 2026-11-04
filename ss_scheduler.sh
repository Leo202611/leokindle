#!/bin/sh
# 待机画面定时调度器（6/9/12/15/18 自动更新）
#
# 架构来自社区 kndl-online-screensaver 的电源事件模型，但按本项目需求大幅精简：
#   * 设备真的 suspend，屏保画面靠 e-ink 双稳态保持，期间屏幕零耗电；
#   * 用 lipc-set-prop -i com.lab126.powerd rtcWakeup <秒> 设 RTC 闹钟，
#     只在 readyToSuspend / wakeupFromSuspend 事件里设（powerd 只在这些状态接受）；
#   * 到点被 RTC 叫醒 -> deferSuspend 防中途睡 -> 单次更新 -> 清 deferSuspend
#     -> 计算下一个更新点 -> 重新挂起。
#   * 完全不调用 keep_awake()、不冻结 GUI、不轮询、不反复整屏重绘。
# 参考命令均已核对上游源码，不靠猜。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ] || SS_HOURS="6 9 12 15 18"
[ -n "${SS_LOG:-}" ]   || SS_LOG="/mnt/us/dash/ss.log"
[ -n "${SS_LAST:-}" ]  || SS_LAST="/mnt/us/dash/ss_last"
[ -n "${SS_DONE:-}" ]  || SS_DONE="/mnt/us/dash/ss_done"
[ -n "${SS_UPDATE_TIMEOUT:-}" ] || SS_UPDATE_TIMEOUT=60
[ -n "${SS_RTC:-}" ]   || SS_RTC=0

RUN_DIR=/tmp/dashss
[ -f "$RUN_DIR/ss_update_once.sh" ] || RUN_DIR=/mnt/us/dash

log() { echo "[$(date +'%m-%d %H:%M:%S')] [sched] $*" >> "$SS_LOG" 2>/dev/null; }

# RTC 闹钟：只用 powerd 的 rtcWakeup —— 上游社区验证过的唯一路径。
#
# 【2026-11-05 07:37 回退】今早曾加过「lipc + 写 /sys/class/rtc/rtc0/wakealarm」
# 双保险，装了那版后用户反馈 Kindle 不定时自我重启。原因：powerd 用相对秒数、
# sysfs 用绝对 epoch，两者抢同一个 RTC；而本机做过校时（dash_fixtime.sh），
# 时钟一旦有偏差，写进去的 ABS 就是「过去」，alarm 立即触发 -> 反复唤醒/重启。
# 上游 kndl-online-screensaver 除禁用时清闹钟外，从不写 sysfs，是有道理的。
# 现在恢复为只走 lipc，并留两个保护：总开关 ss_no_rtc、60 秒设置节流。
RTC_LAST=0
set_rtc_wakeup() {
    S="$1"
    [ "$S" -gt 0 ] || return 0
    # 应急总开关：设备上建 /mnt/us/dash/ss_no_rtc 即完全不碰 RTC
    [ -f /mnt/us/dash/ss_no_rtc ] && { log "ss_no_rtc 存在，跳过 RTC 设置"; return 0; }
    # 节流：powerd 状态抖动时避免 60 秒内反复写 RTC
    NOW=$(date +%s)
    if [ "$RTC_LAST" != "0" ] && [ $(( NOW - RTC_LAST )) -lt 60 ]; then
        return 0
    fi
    RTC_LAST=$NOW
    if lipc-set-prop -i com.lab126.powerd rtcWakeup "$S" >/dev/null 2>&1; then
        log "RTC(lipc) ${S}s 后唤醒"
    else
        log "RTC(lipc) 被拒（当前非 readyToSuspend），不写 sysfs"
    fi
}

# 事件驱动等待：挂起前设闹钟，唤醒后按剩余时间重新设。
# 不 sleep 长轮询，避免 SoC 在等待期间反复醒来空转。
wait_for_suspend() {
    END=$(( $(date +%s) + $1 ))
    # 【关键】先主动设一次闹钟，不能只等 readyToSuspend 事件。
    # 调度器启动时设备可能已经处于屏保/休眠（readyToSuspend 早就发生过），
    # 那样永远等不到事件、闹钟没设、设备直接睡死 —— 这正是 6:00 不更新的
    # 典型成因之一。先设好，后面收到事件再按剩余时间刷新即可。
    REM=$(( END - $(date +%s) ))
    [ "$REM" -gt 0 ] && set_rtc_wakeup "$REM"
    while true; do
        REM=$(( END - $(date +%s) ))
        [ "$REM" -le 0 ] && break
        [ "$REM" -gt 86400 ] && REM=86400
        EV=$(lipc-wait-event -s "$REM" \
             com.lab126.powerd readyToSuspend,wakeupFromSuspend,resuming 2>/dev/null)
        case "$EV" in
            readyToSuspend*|wakeupFromSuspend*|resuming*)
                REM=$(( END - $(date +%s) ))
                [ "$REM" -gt 0 ] && set_rtc_wakeup "$REM"
                ;;
            *)
                # lipc-wait-event 不可用/异常退出时防止忙循环烧电
                REM=$(( END - $(date +%s) ))
                [ "$REM" -gt 60 ] && sleep 10
                ;;
        esac
    done
}

# 距下一个更新点还有多少秒（纯整数运算，BusyBox ash 兼容，不用 date -d / %N）
next_slot_secs() {
    HM=$(date +'%H %M'); H=${HM% *}; M=${HM#* }
    H=$(( ${H#0} )); M=$(( ${M#0} ))
    CUR=$(( H * 60 + M ))
    FIRST=""; NEXT=""
    for s in $SS_HOURS; do
        [ -z "$FIRST" ] && FIRST=$s
        SM=$(( ${s} * 60 ))
        if [ "$SM" -gt "$CUR" ]; then
            if [ -z "$NEXT" ] || [ "$SM" -lt "$NEXT" ]; then NEXT=$SM; fi
        fi
    done
    [ -n "$NEXT" ] || NEXT=$(( 1440 + ${FIRST} * 60 ))
    echo $(( (NEXT - CUR) * 60 ))
}

slot_id() {
    HM=$(date +%H); HH=$(( ${HM#0} ))
    case " $SS_HOURS " in
        *" $HH "*) date +%Y%m%d_%H; return 0 ;;
    esac
    return 1
}

do_update() {
    log "---- 开始更新 ----"
    lipc-set-prop -i com.lab126.powerd deferSuspend $(( SS_UPDATE_TIMEOUT + 15 )) 2>/dev/null
    T0=$(date +%s)
    /bin/sh "$RUN_DIR/ss_update_once.sh" >> "$SS_LOG" 2>&1 &
    UP=$!
    LIM=$(( SS_UPDATE_TIMEOUT + 10 ))
    E=0
    while [ "$E" -lt "$LIM" ]; do
        kill -0 "$UP" 2>/dev/null || break
        sleep 3
        E=$(( E + 3 ))
    done
    if kill -0 "$UP" 2>/dev/null; then
        log "更新超时 ${LIM}s，强制结束（不重试）"
        kill "$UP" 2>/dev/null
        sleep 1
        kill -9 "$UP" 2>/dev/null
    fi
    lipc-set-prop -i com.lab126.powerd deferSuspend 0 2>/dev/null
    log "---- 更新结束 用时 $(( $(date +%s) - T0 ))s ----"
}

log "===== 调度器启动 pid=$$ 更新点: $SS_HOURS RUN_DIR=$RUN_DIR ====="

# 启动补一次：修正可能滞留的旧静态图；20 分钟内刚更新过就跳过，避免 respawn 反复取图
LAST=$(cat "$SS_LAST" 2>/dev/null)
NOW=$(date +%s)
if [ -z "$LAST" ] || [ $(( NOW - ${LAST:-0} )) -gt 1200 ]; then
    log "启动补刷一次"
    do_update
fi

while true; do
    if SID=$(slot_id); then
        DONE=$(cat "$SS_DONE" 2>/dev/null)
        if [ "$DONE" != "$SID" ]; then
            log "到达更新点 $SID"
            do_update
        else
            log "更新点 $SID 本轮已完成"
        fi
    fi
    SECS=$(next_slot_secs)
    log "距下次更新约 $(( SECS / 60 )) 分钟，进入挂起等待"
    wait_for_suspend "$SECS"
    sleep 1
done
