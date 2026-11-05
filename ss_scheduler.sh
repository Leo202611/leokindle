#!/bin/sh
# 待机画面定时调度器
#
# 两种模式由 ss_config.sh 的 SS_RTC 选择：
#   SS_RTC=0（默认，阶段1）：用户态常驻 + deferSuspend 轻休眠，确保定时更新一定发生。
#     不深睡，续航约 1–2 天。适合先验证功能、或阶段2 事件链路在真机不可用时兜底。
#   SS_RTC=1（阶段2）：监听 powerd 的 readyToSuspend / wakeupFromSuspend 事件，
#     在 readyToSuspend 里用 lipc rtcWakeup 设下一次唤醒闹钟并关 WiFi 进入真深睡；
#     RTC 到点唤醒后开 WiFi 取图、刷屏，再回休眠。目标：不接电源撑一周。
#
# 阶段2 关键约束（fanzhh / KindleCron 实证，5.11 原生 powerd）：
#   * rtcWakeup 只能在 readyToSuspend 里设置；直接写 /sys wakealarm 会被 powerd
#     休眠末段用 rtcWakeup=0 覆盖，无效（咱 9:00 失败就是栽在这）。
#   * BusyBox sleep 基于 CLOCK_MONOTONIC，设备休眠时被冻结；所有计时一律用
#     挂钟 date +%s，绝不用 sleep 累计判断间隔。
#   * 唤醒后 WiFi 重连 15–30s+，取图逻辑（ss_update_once.sh）内部已做三段重试。
#   * 唯一真机未知数：5.16.2.1.1 + linkss 接管休眠下，powerd 事件是否照常触发、
#     rtcWakeup 是否真唤醒、eips 在唤醒瞬间能否正确重绘屏保——需在真机验证。
#     验证方式：设 SS_RTC=1 跑几天；若发现整点不更新/不唤醒，改回 SS_RTC=0 即退回阶段1。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ]         || SS_HOURS="6 9 12 15 18"
[ -n "${SS_TEST_INTERVAL:-}" ] || SS_TEST_INTERVAL=0
[ -n "${SS_LOG:-}" ]           || SS_LOG="/mnt/us/dash/ss.log"
[ -n "${SS_LAST:-}" ]          || SS_LAST="/mnt/us/dash/ss_last"
[ -n "${SS_DONE:-}" ]          || SS_DONE="/mnt/us/dash/ss_done"
[ -n "${SS_RTC:-}" ]           || SS_RTC=0

RUN_DIR=/tmp/dashss
[ -f "$RUN_DIR/ss_update_once.sh" ] || RUN_DIR=/mnt/us/dash

log() { echo "[$(date +'%m-%d %H:%M:%S')] [sched] $*" >> "$SS_LOG" 2>/dev/null; }

do_update() {
    log "---- 开始更新 ----"
    T0=$(date +%s)
    /bin/sh "$RUN_DIR/ss_update_once.sh" >> "$SS_LOG" 2>&1
    log "---- 更新结束 用时 $(( $(date +%s) - T0 ))s ----"
}

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

test_mode() { [ "${SS_TEST_INTERVAL:-0}" -gt 0 ]; }

startup_refresh_if_stale() {
    # 启动补一次：修正可能滞留的旧静态图；20 分钟内刚更新过就跳过
    LAST=$(cat "$SS_LAST" 2>/dev/null)
    NOW=$(date +%s)
    if [ -z "$LAST" ] || [ $(( NOW - ${LAST:-0} )) -gt 1200 ]; then
        log "启动补刷一次"
        do_update
    fi
}

# ---- 阶段1：用户态常驻 + deferSuspend 轻休眠（不深睡，续航约 1–2 天）----
phase1_loop() {
    log "===== 阶段1 轻休眠模式（deferSuspend，SS_RTC=$SS_RTC）====="
    startup_refresh_if_stale
    while true; do
        if test_mode; then
            do_update
            SECS=$(( SS_TEST_INTERVAL * 60 ))
        else
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
        fi
        log "心跳：进入等待，距下次约 ${SECS}s（deferSuspend 防冻结）"
        REM=$SECS
        while [ "$REM" -gt 0 ]; do
            CHUNK=60
            [ "$REM" -lt "$CHUNK" ] && CHUNK=$REM
            # 推迟 powerd 休眠，避免本进程被 suspend 冻住；e-ink 仍息屏保持，CPU 轻闲
            lipc-set-prop -i com.lab126.powerd deferSuspend $(( CHUNK + 30 )) 2>/dev/null
            sleep "$CHUNK"
            REM=$(( REM - CHUNK ))
            echo "[$(date +'%m-%d %H:%M:%S')] [sched] alive rem=${REM}s" >> "$SS_LOG" 2>/dev/null
        done
        sleep 1
    done
}

# ---- 阶段2：RTC 真深睡（事件驱动，目标续航一周）----
set_rtc_wakeup() {
    # 以挂钟算「距下一个更新点」的相对秒数（busybox sleep 休眠时冻结，绝不用它计时）
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
    SEC=$(( (NEXT - CUR) * 60 - $(date +%S) ))
    [ "$SEC" -lt 10 ] && SEC=$(( SEC + 60 ))
    # rtcWakeup 只能在 readyToSuspend 里设；重试 4 次提高成功率（fanzhh 做法）
    I=0
    while [ "$I" -lt 4 ]; do
        lipc-set-prop -i com.lab126.powerd rtcWakeup "$SEC" 2>/dev/null
        I=$(( I + 1 ))
    done
    log "rtcWakeup=${SEC}s（下次更新点）"
}

phase2_loop() {
    log "===== 阶段2 RTC 深睡模式（SS_RTC=$SS_RTC）====="
    startup_refresh_if_stale
    log "进入事件监听（goingToScreenSaver / readyToSuspend / wakeupFromSuspend）"
    while true; do
        # 阻塞等待下一个 powerd 事件；无事件则不耗电（区别于阶段1 的轮询）
        EV=$(lipc-wait-event com.lab126.powerd \
                'goingToScreenSaver,wakeupFromSuspend,readyToSuspend' 2>/dev/null)
        # 空返回（lipc 异常/超时）保护：避免空转忙循环
        if [ -z "$EV" ]; then
            sleep 30
            continue
        fi
        case "$EV" in
            *readyToSuspend*)
                # 即将休眠：设下次 RTC 唤醒闹钟 + 关 WiFi 进入真深睡省电
                set_rtc_wakeup
                lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
                log "设唤醒闹钟并关 WiFi，进入深睡"
                ;;
            *wakeupFromSuspend*)
                # 被 RTC 唤醒：开 WiFi -> 取图 -> 刷屏；之后框架自动重新休眠
                log "RTC 唤醒，开始取图"
                lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
                do_update
                ;;
            *goingToScreenSaver*)
                # 进入屏保（如手动按电源，非 RTC 唤醒）：确保下次休眠带唤醒闹钟
                set_rtc_wakeup
                log "进入屏保，已设下次唤醒"
                ;;
        esac
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
