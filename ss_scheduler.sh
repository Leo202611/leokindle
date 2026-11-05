#!/bin/sh
# 待机画面定时调度器（测试版：后台常驻 + 定时调 ss_update_once）
#
# 背景：真机（Kindle 8 / 固件 5.16.2.1.1 + linkss 屏保）上，依赖 powerd
# suspend 事件的「深睡 + RTC 唤醒」链路不通（9:00 未自动更新已证实：
# linkss 接管休眠后 powerd 不按 rtcWakeup 醒来，事件永远不来）。
#
# 本版改用「用户态常驻 + deferSuspend 轻休眠」确保定时更新一定发生，
# 先打通全自动功能；省电（真深睡 RTC 唤醒）作为下一阶段单独攻关。
#
# 测试期：SS_TEST_INTERVAL>0 时，每隔 N 分钟更新一次（高频验证）。
# 生产期：SS_TEST_INTERVAL=0，按 SS_HOURS 白名单在整点更新。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ]         || SS_HOURS="6 9 12 15 18"
[ -n "${SS_TEST_INTERVAL:-}" ] || SS_TEST_INTERVAL=20
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

log "===== 调度器启动 pid=$$ test_interval=${SS_TEST_INTERVAL}min hours=$SS_HOURS RUN_DIR=$RUN_DIR ====="

# 启动补一次：修正可能滞留的旧静态图；20 分钟内刚更新过就跳过
LAST=$(cat "$SS_LAST" 2>/dev/null)
NOW=$(date +%s)
if [ -z "$LAST" ] || [ $(( NOW - ${LAST:-0} )) -gt 1200 ]; then
    log "启动补刷一次"
    do_update
fi

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
