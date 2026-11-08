#!/bin/sh
# 待机画面定时调度器
#
# 两种模式由 ss_config.sh 的 SS_RTC 选择：
#   SS_RTC=0（默认，阶段1）：用户态常驻 + deferSuspend 轻休眠，确保定时更新一定发生。
#     不深睡，续航约 1–2 天。适合先验证功能、或阶段2 事件链路在真机不可用时兜底。
#   SS_RTC=1（阶段2）：真深睡 + RTC 闹钟每小时唤醒，目标不接电源撑一周。
#     2026-11-08 按上游 kndl-online-screensaver 架构重写，修复「整点全不醒」：
#       * 主循环用「挂钟绝对截止时刻 + lipc-wait-event -s <剩余秒>」带超时等待，
#         事件流断了超时也会返回，不再无限阻塞；
#       * rtcWakeup 只在 readyToSuspend 状态设置并检查返回码（其它状态 powerd
#         返回 lipcPropErrInvalidState，旧版在这些状态静默失败却以为兜底生效）；
#       * 闹钟设置失败 → 自动切换「保持唤醒」模式，靠挂钟看门狗保证整点更新，
#         下一周期重试成功后自动回到深睡；不是永久降级，是按周期自愈。
#
# 阶段2 关键约束（上游源码 / MobileRead t=236104 / fanzhh 实证）：
#   * rtcWakeup 只在 readyToSuspend 被 powerd 接受；直接写 /sys wakealarm 会被
#     powerd 休眠末段用 rtcWakeup=0 覆盖，无效（只读校验可以做，不要写）。
#   * lipc-wait-event 要同时监听 wakeupFromSuspend 与 resuming（部分机型只发其一）。
#   * BusyBox sleep 基于 CLOCK_MONOTONIC，设备休眠时被冻结；所有计时一律用
#     挂钟 date +%s，绝不用 sleep 累计判断间隔。
#   * 唤醒后 WiFi 重连 15–30s+，取图逻辑（ss_update_once.sh）内部已做三段重试。
#   * 每次设闹钟成功/失败、每次更新都写日志，便于回溯「哪一轮闹钟没设上」。
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

# ---- 阶段2：RTC 真深睡（挂钟截止 + 带超时事件循环 + 闹钟校验 + 自愈）----
# 距下一个更新点的秒数；全部用挂钟计算，绝不依赖 suspend 时被冻结的 sleep 累计。
secs_to_next_slot() {
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
    S=$(( (NEXT - CUR) * 60 - $(date +%S) ))
    [ "$S" -lt 10 ] && S=$(( S + 60 ))
    echo "$S"
}

# 只在 readyToSuspend 状态调用。检查 lipc 返回码与 stderr：
# powerd 在其它状态会返回 lipcPropErrInvalidState，旧版静默忽略却以为设上了。
set_rtc_wakeup() {
    SEC="$1"; REASON="${2:-suspend}"
    [ "$SEC" -gt 0 ] || { log "RTC($REASON): 秒数非法 $SEC"; return 1; }
    OUT=$(lipc-set-prop -i com.lab126.powerd rtcWakeup "$SEC" 2>&1); RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qiE 'error|invalid'; then
        AL=""; F=""
        for F in /sys/class/rtc/rtc0/wakealarm /sys/class/rtc/rtc1/wakealarm; do
            [ -r "$F" ] && { AL=$(cat "$F" 2>/dev/null); break; }
        done
        log "RTC($REASON): OK ${SEC}s 后唤醒 (wakealarm=${AL:-不可读})"
        return 0
    fi
    log "RTC($REASON): 失败 rc=$RC out=$OUT"
    return 1
}

phase2_loop() {
    log "===== 阶段2 RTC 深睡（挂钟看门狗版，SS_RTC=$SS_RTC）====="
    startup_refresh_if_stale
    # 上游实证：wakeupFromSuspend 与 resuming 都要监听（部分机型只发其一）。
    # goingToScreenSaver 仅记录，不在该状态设闹钟（会被 powerd 拒绝）。
    EVENTS='readyToSuspend,wakeupFromSuspend,resuming,goingToScreenSaver'

    while true; do
        # 本轮以挂钟绝对截止时刻为准，全程不受事件流是否中断影响。
        SECS=$(secs_to_next_slot)
        ENDWAIT=$(( $(date +%s) + SECS ))
        ALARM_OK=0
        TRIES=0
        log "本轮 ${SECS}s 后截止（ENDWAIT=$ENDWAIT）"

        # 等待窗口：-s 超时保证「一个事件都不来」也会返回，绝不无限阻塞。
        # 闹钟未确认时把单次等待切成 60s 小段，每返回一次续 deferSuspend，
        # 防止看门狗进程在等待中途被 powerd 冻住（否则自愈会失效）。
        while :; do
            NOW=$(date +%s)
            REMAIN=$(( ENDWAIT - NOW ))
            [ "$REMAIN" -le 0 ] && break
            WAITSEC=$REMAIN
            if [ "$ALARM_OK" = "0" ] && [ "$WAITSEC" -gt 60 ]; then WAITSEC=60; fi
            EV=$(lipc-wait-event -s "$WAITSEC" com.lab126.powerd "$EVENTS" 2>/dev/null)
            if [ "$ALARM_OK" = "0" ]; then
                # 闹钟未确认：续期保持唤醒；sleep 5 抑制事件风暴导致的高频空转
                # （真机 -s 60 本就阻塞，这层是双保险，代价可忽略）。
                lipc-set-prop -i com.lab126.powerd deferSuspend 120 2>/dev/null
                sleep 5
            fi
            case "$EV" in
                *readyToSuspend*)
                    R=$(( ENDWAIT - $(date +%s) ))
                    [ "$R" -lt 10 ] && R=10
                    # 每轮最多尝试 3 次，避免事件风暴下高频空转耗电；
                    # 超过后只靠挂钟看门狗保持唤醒，不再重复 lipc 调用。
                    if [ "$TRIES" -lt 3 ]; then
                        TRIES=$(( TRIES + 1 ))
                        if set_rtc_wakeup "$R" suspend; then
                            ALARM_OK=1
                            lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
                        else
                            # 自愈：闹钟没设上就绝不让设备睡死。deferSuspend 保持唤醒，
                            # 靠挂钟超时在本轮截止时刻照常更新；下一轮自动重试。
                            lipc-set-prop -i com.lab126.powerd deferSuspend $(( R + 60 )) 2>/dev/null
                            log "闹钟失败(第${TRIES}次) -> deferSuspend 保持唤醒，看门狗接管本轮"
                        fi
                    fi
                    ;;
                *wakeupFromSuspend*|*resuming*)
                    # 防更新途中被 powerd 重新挂起
                    lipc-set-prop -i com.lab126.powerd deferSuspend 180 2>/dev/null
                    log "收到唤醒/恢复事件: $EV"
                    ;;
                *goingToScreenSaver*)
                    log "进入屏保（只在 readyToSuspend 时设闹钟）"
                    ;;
            esac
        done

        # 到点必更新：这是目标本身。闹钟是否设上只影响「中间能否深睡省电」，
        # 不影响「整点一定刷新」。
        log "到达更新点，开始更新（本轮闹钟=${ALARM_OK}）"
        if wifi_restore; then
            do_update
        else
            log "WiFi 未恢复，跳过本次取图（下个整点再试）"
        fi
        lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
        lipc-set-prop -i com.lab126.powerd deferSuspend 0 2>/dev/null
        sleep 1
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
