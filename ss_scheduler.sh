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

# ---- 阶段2：事件驱动 + powerd 原生挂起（5.16.x 实测可靠的「不睡死」方案，方案C）----
# 把挂起生命周期完全交还 powerd，脚本只做两件事：
#   1) 监听 powerd 事件 → 取图刷屏（goingToScreenSaver / wakeupFromSuspend）；
#   2) 在每次 readyToSuspend 设好下次 RTC 唤醒。
# 不调 preventScreenSaver、不自己 echo mem、不写 wakealarm——彻底避免与 powerd 竞争。
# 核心不变量：readyToSuspend 每轮必设 rtcWakeup（吃满 powerd 重复事件），故永不睡死。
# 事件时序（用户按电源进待机）：goingToScreenSaver → … → readyToSuspend → 挂起
# 唤醒（RTC/电源键）：wakeupFromSuspend → resuming → (无操作则) goingToScreenSaver → readyToSuspend
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

set_rtc_wakeup() {
    # 只在 readyToSuspend 等 powerd 接受 rtcWakeup 的状态调用（此固件 rtcWakeup 仅在该态有效）。
    # 相对秒数；每轮 readyToSuspend 都设，吃满 powerd 重复事件，避免被 rtcWakeup=0 覆盖。
    SECS=$(secs_to_next_slot)
    if lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" 2>/dev/null; then
        log "rtcWakeup 已设 ${SECS}s（下次槽位）"
    else
        log "rtcWakeup 设置失败（本轮回退，等下次 readyToSuspend 再设）"
    fi
}

# 后台触发取图刷屏，避免阻塞事件循环导致 readyToSuspend 来不及设闹钟（旧版会「下一次整点不醒」）。
# 锁文件含两样：PID（/tmp/ss_updating）+ 启动时间戳（/tmp/ss_updating.ts）。
# 关键鲁棒性（2026-11-08 补强）：Kindle 在 RTC 唤醒后若很快重新挂起，后台 do_update 会被
# 「冻结」在 suspended 态（WiFi 仍开着、PID 仍存活，kill -0 为真）。普通 PID 锁会误判「仍在跑」
# 从而跳过本回合乃至之后所有整点的更新。故额外用时间戳判定：进程存活但已运行超过
# SS_UPD_MAXS 秒（远超正常 40–60s 的取图耗时，典型是跨整点被挂起冻结了数千秒），视为僵死，
# 直接 kill -9 后重来。这样无论固件是「唤醒后长驻数十秒」还是「唤醒后秒级挂起」，每小时都可靠更新：
#   前者：do_update 在挂起前跑完并删锁，下个整点正常触发；
#   后者：冻结进程在下一整点被时间戳判定为僵死清掉，新更新照常进行。
SS_UPD_MAXS="${SS_UPD_MAXS:-150}"
trigger_update() {
    if [ -f /tmp/ss_updating ]; then
        OPID=$(cat /tmp/ss_updating 2>/dev/null)
        TS=$(cat /tmp/ss_updating.ts 2>/dev/null)
        NOW=$(date +%s)
        if [ -n "$OPID" ] && kill -0 "$OPID" 2>/dev/null; then
            if [ -n "$TS" ] && [ $(( NOW - TS )) -gt "$SS_UPD_MAXS" ]; then
                log "trigger_update：更新进程(pid=$OPID)已运行 $(( NOW - TS ))s，疑似被挂起冻结，kill -9 后重来"
                kill -9 "$OPID" 2>/dev/null
                rm -f /tmp/ss_updating /tmp/ss_updating.ts
            else
                log "trigger_update：已有更新在跑(pid=$OPID)，跳过"
                return 0
            fi
        else
            rm -f /tmp/ss_updating /tmp/ss_updating.ts
        fi
    fi
    ( SS_FORCE_EIPS=1 SS_SNAP=1 do_update; rm -f /tmp/ss_updating /tmp/ss_updating.ts ) &
    echo $! > /tmp/ss_updating
    echo "$(date +%s)" > /tmp/ss_updating.ts
}

phase2_loop() {
    log "===== 阶段2 事件驱动（powerd 原生挂起 + readyToSuspend 每轮设 rtcWakeup, SS_RTC=$SS_RTC）====="
    # 清除旧版（方案B）可能残留的 preventScreenSaver=1：该 lipc 标志在进程被杀后仍持久，
    # 不复位则「按电源键进待机」继续被禁用。方案C 从不设置它，此处仅做一次性清理。
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    rm -f /tmp/ss_updating
    startup_refresh_if_stale
    while true; do
        # -m 进入 monitor 模式持续吐事件，管道逐行交给 case 处理。
        # 关键修复：取图刷屏（trigger_update）一律后台跑，事件循环本身不被阻塞，
        # 这样 readyToSuspend 一到就能立刻设好下次 RTC 闹钟，杜绝「下一次整点不醒」。
        lipc-wait-event -m com.lab126.powerd \
            goingToScreenSaver,wakeupFromSuspend,readyToSuspend,exitingScreenSaver \
            | while read EV; do
            case "$EV" in
                goingToScreenSaver*)
                    # 进待机事件：不在此触发取图（2026-11-08 复盘修复）。
                    # 旧逻辑在此跑 do_update，但「按电源键进待机」时 powerd 随即挂起，
                    # 后台取图会被冻结在 suspended 态（WiFi 还开着），直到下一个 RTC 唤醒
                    # 才恢复；而恢复时 wakeupFromSuspend 因 /tmp/ss_updating 锁未释放而
                    # 跳过本回合更新 -> 「手动休眠一次后，后续整点不更新」的真实 bug。
                    # 实际无需在此取图：ss_update_once.sh 每次成功更新都已把最新图写进
                    # linkss/screensavers/bg_ss00.png，powerd 在 suspend 那一刻由 linkss
                    # 重读该文件显示，即用户按电源休眠看到的就是最近一次自动更新的画面
                    # （最多落后一个槽位，待机画面可接受）。真正的定时更新由
                    # wakeupFromSuspend 负责，本分支保持空操作即可。
                    log "事件 goingToScreenSaver：挂起即由 linkss 显示当前 bg_ss00.png，无需取图"
                    ;;
                wakeupFromSuspend*)
                    # RTC 到点 / 手动唤醒：等电源键抖动平息，刷一次最新图。
                    # 同时尽力早设闹钟（部分固件 wakeupFromSuspend 态也接受 rtcWakeup，
                    # 失败静默，交给紧随的 readyToSuspend 兜底——循环已不被阻塞故能及时设）。
                    log "事件 wakeupFromSuspend：唤醒后刷一次"
                    sleep 2
                    SECS=$(secs_to_next_slot)
                    lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" >/dev/null 2>&1
                    trigger_update
                    ;;
                readyToSuspend*)
                    # 即将挂起：每轮必设下次 RTC 唤醒（不设防抖）。WiFi 由 do_update 自管。
                    set_rtc_wakeup
                    ;;
                exitingScreenSaver*)
                    # 用户按电源退出待机：恢复 WiFi 以便后续联网（do_update 也会按需重连）。
                    log "事件 exitingScreenSaver：恢复 WiFi"
                    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
                    lipc-set-prop com.lab126.wifid enable 1 2>/dev/null
                    ;;
            esac
        done
        # lipc-wait-event 异常退出（极少见）时回到循环顶部重启监听，避免调度器静默死亡。
        log "lipc-wait-event 退出，2s 后重启监听"
        sleep 2
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
