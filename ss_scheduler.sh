#!/bin/sh
# 待机画面定时调度器
#
# 两种模式由 ss_config.sh 的 SS_RTC 选择：
#   SS_RTC=0（默认，阶段1）：用户态常驻 + deferSuspend 轻休眠，确保定时更新一定发生。
#     不深睡，续航约 1–2 天。适合先验证功能、或阶段2 事件链路在真机不可用时兜底。
#   SS_RTC=1（阶段2）：真深睡 + RTC 闹钟每小时唤醒，目标不接电源撑一周。
#
# 阶段2 实现演进（均已在 Kindle 8 / 5.16.2.1.1 真机验证）：
#   方案A（弃·rtcWakeup 单点设置）：只在 readyToSuspend 设一次 → powerd 重复
#     readyToSuspend 时用 rtcWakeup=0 覆盖 → 08/11/12 整点永久睡死。
#   方案B（弃·preventScreenSaver+echo mem）：preventScreenSaver 在 5.16.x 会
#     同时禁用「按电源键人工进待机」，且 echo mem 被框架静默忽略 → 卡 GUI 不挂起。
#   方案C（现采用·事件驱动，联网核实 Basti189/onlinescreensaverPW2 上游）：
#     把挂起生命周期完全交还 powerd，脚本只监听事件：
#       * goingToScreenSaver → 进待机前刷一次（强制 eips 写帧缓冲 + 截图）
#       * wakeupFromSuspend  → 唤醒后刷一次（RTC/电源键唤醒都走这）
#       * readyToSuspend     → 每轮必设 rtcWakeup=下次槽位秒数（不设防抖，吃满
#                               powerd 重复事件，这是「不睡死」的核心。上游原话：
#                               "Kindle powerd repeats readyToSuspend on purpose.
#                                Always set the RTC wakeup on every readyToSuspend."）
#       * exitingScreenSaver → 恢复 WiFi
#     不调 preventScreenSaver、不自己 echo mem、不写 wakealarm——彻底避免与 powerd 竞争。
#   WiFi 开/关由 ss_update_once.sh 内部按 WIFI_WAS 自行管理，调度器不重复操作。
#   计时一律用挂钟 date +%s（BusyBox sleep 基于 CLOCK_MONOTONIC，休眠时被冻结）。
#   每次挂起/唤醒/更新都写日志，便于回溯「哪一轮没醒」。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

# 脚本版本号：每次实质改动都 +1，便于从 ntfy 遥测确认设备上跑的是哪一版。格式 YYYYMMDD.N。
SVER="20261108.5"

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ]         || SS_HOURS="6 9 12 15 18"
[ -n "${SS_SLOT_MINUTES:-}" ]  || SS_SLOT_MINUTES="0"
[ -n "${SS_TEST_INTERVAL:-}" ] || SS_TEST_INTERVAL=0
[ -n "${SS_LOG:-}" ]           || SS_LOG="/mnt/us/dash/ss.log"
[ -n "${SS_LAST:-}" ]          || SS_LAST="/mnt/us/dash/ss_last"
[ -n "${SS_DONE:-}" ]          || SS_DONE="/mnt/us/dash/ss_done"
[ -n "${SS_RTC:-}" ]           || SS_RTC=0

RUN_DIR=/tmp/dashss
[ -f "$RUN_DIR/ss_update_once.sh" ] || RUN_DIR=/mnt/us/dash

log() { echo "[$(date +'%m-%d %H:%M:%S')] [sched] $*" >> "$SS_LOG" 2>/dev/null; }

# 【临时遥测 2026-11-08】每次事件把关键电源/WiFi 状态上报 ntfy，便于 Mac 端远程定位
# 22:20 仍失败的根因（RTC 是否真的唤醒、rtcWakeup 设上没有、卡在 freeze 还是 sleep-death）。
# 最好努力、失败静默，绝不干扰主逻辑。稳定后整段可删。
DBG_TOPIC="k8dash_dbg_9c1e"
dbg() {
    EV="$1"
    DF=$(lipc-get-prop com.lab126.powerd deferSuspend 2>/dev/null)
    RT=$(lipc-get-prop com.lab126.powerd rtcWakeup 2>/dev/null)
    CM=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    MSG="$(date +'%m-%d %H:%M:%S') [v$SVER] EV=$EV defer=${DF:-?} rtc=${RT:-?} wifi=${CM:-?} slot=$(date +%H:%M)"
    curl -sL -k -m 5 -X POST -H "Title: sched-debug" --data-binary "$MSG" "https://ntfy.sh/$DBG_TOPIC" >/dev/null 2>&1
}

do_update() {
    log "---- 开始更新 ----"
    T0=$(date +%s)
    /bin/sh "$RUN_DIR/ss_update_once.sh" >> "$SS_LOG" 2>&1
    log "---- 更新结束 用时 $(( $(date +%s) - T0 ))s ----"
}

# 基于 SS_SLOT_MINUTES（每小时内的分钟槽位，如 "0 20 40"）算距下次唤醒的秒数。
# SS_SLOT_MINUTES 是「小时内的分钟」，不再乘 60；NEXT 也以分钟计，乘以 60 得秒。
next_slot_secs() {
    M=$(date +'%M'); M=$(( ${M#0} ))
    FIRST=""; NEXT=""
    for s in $SS_SLOT_MINUTES; do
        [ -z "$FIRST" ] && FIRST=$s
        if [ "$s" -gt "$M" ]; then
            if [ -z "$NEXT" ] || [ "$s" -lt "$NEXT" ]; then NEXT=$s; fi
        fi
    done
    [ -n "$NEXT" ] || NEXT=$(( 60 + ${FIRST} ))
    echo $(( (NEXT - M) * 60 ))
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
    dbg "BOOT v$SVER phase1 rtc=$SS_RTC"
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

# ---- 阶段2：事件驱动 + powerd 原生挂起（5.16.x 实测可靠的「不睡死」方案，方案C）----
# 把挂起生命周期完全交还 powerd，脚本只做两件事：
#   1) 监听 powerd 事件 → 取图刷屏（goingToScreenSaver / wakeupFromSuspend）；
#   2) 在每次 readyToSuspend 设好下次 RTC 唤醒。
# 不调 preventScreenSaver、不自己 echo mem、不写 wakealarm——彻底避免与 powerd 竞争。
# 核心不变量：readyToSuspend 每轮必设 rtcWakeup（吃满 powerd 重复事件），故永不睡死。
# 事件时序（用户按电源进待机）：goingToScreenSaver → … → readyToSuspend → 挂起
# 唤醒（RTC/电源键）：wakeupFromSuspend → resuming → (无操作则) goingToScreenSaver → readyToSuspend
# 同上，但减去当前秒数得到精确的 rtcWakeup 相对秒数（phase2 用）。
# 基于 SS_SLOT_MINUTES（每小时内的分钟槽位）。
secs_to_next_slot() {
    M=$(date +'%M'); M=$(( ${M#0} ))
    FIRST=""; NEXT=""
    for s in $SS_SLOT_MINUTES; do
        [ -z "$FIRST" ] && FIRST=$s
        if [ "$s" -gt "$M" ]; then
            if [ -z "$NEXT" ] || [ "$s" -lt "$NEXT" ]; then NEXT=$s; fi
        fi
    done
    [ -n "$NEXT" ] || NEXT=$(( 60 + ${FIRST} ))
    S=$(( (NEXT - M) * 60 - $(date +%S) ))
    [ "$S" -lt 10 ] && S=$(( S + 60 ))
    echo "$S"
}

set_rtc_wakeup() {
    # 只在 readyToSuspend 等 powerd 接受 rtcWakeup 的状态调用（此固件 rtcWakeup 仅在该态有效）。
    # 相对秒数；每轮 readyToSuspend 都设，吃满 powerd 重复事件，避免被 rtcWakeup=0 覆盖。
    SECS=$(secs_to_next_slot)
    if lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" 2>/dev/null; then
        log "rtcWakeup 已设 ${SECS}s（下次槽位）"
        dbg "RTCSET ${SECS}s"
    else
        log "rtcWakeup 设置失败（本轮回退，等下次 readyToSuspend 再设）"
        dbg "RTCFAIL"
    fi
}

# 2026-11-08 23:00 复盘：原 trigger_update()（后台子进程 + PID/时间戳锁）已弃用。
# 阶段2 改为「主循环前台调用 do_update + wait_for_suspend 单次 lipc-wait-event 循环」，
# 不再依赖 -m 常驻监听，天然抗 suspend/resume，逻辑更简单也更稳。详见下方 phase2_loop。



# 电池友好的等待 + 挂起编排（对齐上游 zpetterd/kndl-online-screensaver 的 wait_for_suspend）：
# 用「单次 lipc-wait-event -s REMAINING」循环，而非 -m 常驻监听。
# 【关键修复 2026-11-08 23:00 睡死根因】5.16.x 下 lipc 的 -m 长连接会在 suspend/resume 后被
# 内核 / lipc-daemon 静默丢弃（连接失效），导致 RTC 唤醒后脚本永远收不到 wakeupFromSuspend、
# 既不更新也不重设闹钟，设备随后永久睡死。-s 单次模式每轮重建连接，天然抗 suspend/resume。
# 每次 readyToSuspend（powerd 即将挂起）用「距下次槽位的剩余秒数」武装 RTC；
# 唤醒（wakeupFromSuspend/resuming）时再次武装（best-effort），随后循环直到 REMAINING<=0 才返回，
# 回到主循环触发取图刷屏。
wait_for_suspend() {
    WAIT_SECONDS=$1
    [ "$WAIT_SECONDS" -gt 0 ] 2>/dev/null || WAIT_SECONDS=60
    END=$(( $(date +%s) + WAIT_SECONDS ))
    while true; do
        NOW=$(date +%s)
        REMAINING=$(( END - NOW ))
        if [ "$REMAINING" -le 0 ]; then
            dbg "WAITDONE rem=${REMAINING}"
            break
        fi
        dbg "WAIT rem=${REMAINING} (arm rtc on readyToSuspend)"
        EVENT=$(lipc-wait-event -s "$REMAINING" com.lab126.powerd \
            readyToSuspend,wakeupFromSuspend,resuming 2>/dev/null)
        case "$EVENT" in
            readyToSuspend*)
                set_rtc_wakeup
                ;;
            wakeupFromSuspend*|resuming*)
                # 唤醒后抢先武装（部分固件 wakeupFromSuspend 态也接受 rtcWakeup，失败静默）
                SECS=$(secs_to_next_slot)
                lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" >/dev/null 2>&1
                dbg "WAKE-arm ${SECS}s"
                ;;
        esac
    done
}

phase2_loop() {
    log "===== 阶段2 事件驱动（powerd 原生挂起 + 单次 lipc-wait-event 循环, SS_RTC=$SS_RTC）====="
    dbg "BOOT v$SVER phase2 rtc=$SS_RTC"
    # 清除旧版（方案B）可能残留的 preventScreenSaver=1：该 lipc 标志在进程被杀后仍持久，
    # 不复位则「按电源键进待机」继续被禁用。方案C 从不设置它，此处仅做一次性清理。
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    rm -f /tmp/ss_updating
    startup_refresh_if_stale
    while true; do
        STATUS=$(lipc-get-prop com.lab126.powerd status 2>/dev/null)
        case "$STATUS" in
            *Screen*Saver*|*Ready*|*Suspended*)
                # 空闲（屏保/待机/已挂起）：先取图刷屏，再武装 RTC 等待到下次槽位。
                log "主循环：空闲($STATUS) → 取图刷屏"
                dbg "IDLE upd"
                SS_SNAP=1 do_update
                # 【关键修复 2026-11-08 23:20 睡死(二)】do_update 内部设了 deferSuspend 240
                # 阻止更新途中被挂起；但若不在更新后立刻解除，设备会被「推迟挂起」撑到 240s 后才真睡，
                # 而我们在更新过程中于 readyToSuspend 设的 rtcWakeup（几十秒后）早已过期，
                # 真睡下时已无有效闹钟 → 永久睡死（正是 23:20 那次的现象）。
                # 故更新一结束立刻 deferSuspend 0，让设备立即进入可挂起态；随后的
                # readyToSuspend 会用「距下次槽位」重新武装 rtcWakeup（对齐上游 wait_for_suspend）。
                lipc-set-prop -i com.lab126.powerd deferSuspend 0 2>/dev/null
                WAIT=$(secs_to_next_slot)
                [ -z "$WAIT" ] && WAIT=60
                log "主循环：等待 ${WAIT}s 到下次槽位（期间允许挂起）"
                dbg "WILLWAIT ${WAIT}s"
                wait_for_suspend "$WAIT"
                ;;
            *Active*)
                # 用户正在使用：不要抢挂起，等其进屏保再接管（每 180s 轮询一次状态）
                log "主循环：Active → 等 goingToScreenSaver（180s）"
                lipc-wait-event -s 180 com.lab126.powerd goingToScreenSaver 2>/dev/null
                ;;
            *)
                log "主循环：未知状态($STATUS) → 等 60s"
                wait_for_suspend 60
                ;;
        esac
        sleep 1
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
