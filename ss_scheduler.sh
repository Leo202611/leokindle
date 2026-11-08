#!/bin/sh
# 待机画面定时调度器
#
# 两种模式由 ss_config.sh 的 SS_RTC 选择：
#   SS_RTC=0（默认，阶段1）：用户态常驻 + deferSuspend 轻休眠，确保定时更新一定发生。
#     不深睡，续航约 1–2 天。适合先验证功能、或阶段2 事件链路在真机不可用时兜底。
#   SS_RTC=1（阶段2）：真深睡 + RTC 闹钟每小时唤醒，目标不接电源撑一周。
#     2026-11-08 实测旧版「rtcWakeup 事件」方案三轮睡死（08/11/12 点整点不醒）：
#     根因 rtcWakeup 仅在 readyToSuspend 被 powerd 接受，漏抓/处理慢即被
#     powerd 用 rtcWakeup=0 覆盖 → 永久睡死。已联网核实并改用更可靠方案：
#     脚本启动即 preventScreenSaver 1 剥夺 powerd 挂起权；每次循环由脚本自己
#     写 /sys/class/rtc/rtc0/wakealarm + echo mem 主动挂起（ragman KT3 同机型 /
#     64mb / homecircuits 实测可行），不依赖 powerd 事件，无竞争、不睡死。
#
# 阶段2 关键约束（联网核实：ragman.net KT3 同机型 / 64mb.org / homecircuits.eu / fanzhh）：
#   * 直接写 wakealarm + 自己 echo mem 可行，前提是不让 powerd 自行走完它的挂起流程
#     （那一步会用 rtcWakeup=0 覆盖闹钟）。故启动先 preventScreenSaver 1。
#   * wakealarm 先 echo 0 清零再写绝对 epoch；个别内核只接受 "+N" 相对写法，已回退。
#   * BusyBox sleep 基于 CLOCK_MONOTONIC，设备休眠时被冻结；所有计时一律用
#     挂钟 date +%s，绝不用 sleep 累计判断间隔。
#   * 唤醒后 WiFi 重连 15–150s（dance 模式），取图逻辑（ss_update_once.sh）内部已做重试。
#   * echo mem 若被框架忽略（个别固件），安全网 sleep 到整点，不深睡但按时更新、不睡死。
#   * 每次挂起/唤醒/更新都写日志，便于回溯「哪一轮没醒」。
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
        # 开机时 GUI 活跃(status=Active)，必须强制 eips 才能把图写到帧缓冲；
        # 否则随后挂起时 e-ink 双稳态保留旧画面，自动更新"看不见"。开机也顺手截图。
        SS_FORCE_EIPS=1 SS_SNAP=1 do_update
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

# ---- 阶段2：内核 RTC 真深睡（脚本自主挂起，不依赖 powerd 事件，根除睡死）----
# 旧版「rtcWakeup 事件」三轮睡死（08/11/12 点整点不醒）：rtcWakeup 仅在 readyToSuspend
# 被 powerd 接受，漏抓/处理慢即被 powerd 用 rtcWakeup=0 覆盖 → 永久睡死。
# 新方案（联网核实 ragman KT3 同机型 / 64mb / homecircuits 实测可行）：
#   启动即 preventScreenSaver 1 剥夺 powerd 挂起权（也就不会覆盖 wakealarm）；
#   每次循环由脚本自己：取图刷屏 → 关 WiFi → 写 /sys/class/rtc/rtc0/wakealarm（绝对 epoch，
#   先 echo 0 清再写；失败回退相对 +N）→ echo mem 主动挂起。RTC 到点由内核唤醒，
#   脚本从 echo mem 后继续，完全不依赖 powerd 事件，无竞争、不睡死。
#   e-ink 双稳态：挂起前已 eips 好新图，挂起期间画面保持，唤醒即正确。
#   若 wakealarm/echo mem 不可用，安全网 sleep 到整点（不深睡但按时更新，绝不睡死）。
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

RTC=/sys/class/rtc/rtc0/wakealarm
[ -w "$RTC" ] || RTC=/sys/class/rtc/rtc1/wakealarm

# 写 RTC 闹钟并主动挂起至绝对时刻 EPOCH。返回后即为唤醒（RTC 到点或手动电源键）。
# 返回 0=已挂起并唤醒；非 0=写闹钟失败（调用方回退轮询）。
kernel_suspend_until() {
    EPOCH="$1"
    echo 0 > "$RTC" 2>/dev/null
    if ! echo "$EPOCH" > "$RTC" 2>/dev/null; then
        # 个别内核只接受相对写法 "+N"
        echo 0 > "$RTC" 2>/dev/null
        echo "+$(( EPOCH - $(date +%s) ))" > "$RTC" 2>/dev/null || return 1
    fi
    GOT=$(cat "$RTC" 2>/dev/null)
    [ -n "$GOT" ] || return 1
    log "内核挂起至 epoch=$EPOCH (wakealarm=$GOT)"
    echo mem > /sys/power/state 2>/dev/null
    # 安全网：若内核未真正挂起（echo mem 被框架忽略），此处立即返回；
    # 用 sleep 顶到整点，避免忙等/睡死，最坏只是不深睡、仍按时更新。
    NOW=$(date +%s)
    if [ "$NOW" -lt "$EPOCH" ]; then
        sleep $(( EPOCH - NOW ))
    fi
    return 0
}

phase2_loop() {
    log "===== 阶段2 内核RTC深睡（脚本自主挂起, SS_RTC=$SS_RTC）====="
    # 关键：剥夺 powerd 自行挂起权，避免它走完自己的挂起流程并用 rtcWakeup=0 覆盖闹钟。
    # 挂起时机此后完全由本脚本掌控（echo mem），从根本上消除睡死竞争。
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
    startup_refresh_if_stale
    while true; do
        # 唤醒后（RTC 到点 / 手动电源键）从这里继续；循环顶部先确保 preventScreenSaver 仍生效
        lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
        # 1) 开 WiFi + 取新图 + 强制刷屏（SS_FORCE_EIPS=1）+ 截图上传（SS_SNAP=1）
        if wifi_restore; then
            SS_FORCE_EIPS=1 SS_SNAP=1 do_update
        else
            log "WiFi 未恢复，跳过本次取图（下个更新点再试）"
        fi
        # 2) 关 WiFi 省电
        lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
        # 3) 等墨水稳定（eips 全刷后需数秒才定影）
        sleep 5
        # 4) 算下次唤醒时刻并挂起
        SECS=$(secs_to_next_slot)
        ENDWAIT=$(( $(date +%s) + SECS ))
        if [ -w "$RTC" ]; then
            kernel_suspend_until "$ENDWAIT"
        else
            log "wakealarm 不可用，回退常驻轮询（不深睡）"
            NOW=$(date +%s)
            [ "$NOW" -lt "$ENDWAIT" ] && sleep $(( ENDWAIT - NOW ))
        fi
        # 5) 回到循环顶部，被 RTC 唤醒后继续取新图
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
