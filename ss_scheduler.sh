#!/bin/sh
# 待机画面定时调度器
#
# 两种模式由 ss_config.sh 的 SS_RTC 选择：
#   SS_RTC=0（阶段1）：用户态常驻 + deferSuspend 轻休眠，不深睡，续航约 1–2 天。
#   SS_RTC=1（阶段2）：真深睡 + RTC 闹钟定时唤醒，目标不接电源撑一周。
#
# 【2026-11-09 全面回退】阶段2 恢复为 11/7 实证基线(commit 894d0a6)架构，
# 并逐条用三份 upstream「main 分支真实源码」校核（原文已下载到 /tmp/upstream/）：
#   fanzhh/kindle-calendar-weather     kindle/dash-daemon.sh（Kindle 7 实机，每小时真深睡唤醒）
#   Basti189/onlinescreensaverPW2      bin/scheduler.sh + utils.sh（PW2 事件驱动 + linkss）
#   zpetterd/kndl-online-screensaver  kindle/bin/scheduler.sh + utils.sh（PW2 主循环式）
# 该基线在 11/8 00:00–08:00 连续 8 次每整点自动更新成功（电量上报可证，8.6%/天）。
# 11/8 上午起把它逐条改坏，全天 12 次提交、0 次成功，故全部撤销：
#   ① 「无限阻塞等单个 powerd 事件」→「lipc-wait-event -s REMAINING 超时循环」：
#      suspend 期间 CLOCK_MONOTONIC 冻结，超时永不返回（23:37 WAIT rem=161 后永久静默）。
#   ② 丢掉「readyToSuspend 关 WiFi」：三家 upstream 都主动 wirelessEnable 0。
#   ③ 改用 /sys/class/rtc/rtc0/wakealarm 绝对闹钟「设」唤醒：
#      fanzhh dash-daemon.sh L9-11 明确证伪（powerd 休眠末段会用 rtcWakeup 覆盖它，不会唤醒）；
#      zpetterd 的 sysfs 只用于进程退出时 echo 0 清理，从不用来设闹钟 —— 11/8 误读了这点。
#   ④ 在 readyToSuspend 回调里塞 ntfy POST（dbg() 含 curl -m 5）：upstream 回调零网络 I/O。
# 【2026-11-09 00:4x 再修正】上面 11/7 基线只抄了 fanzhh 的「一半」：
#   它只有「单进程无限阻塞等事件」，缺了 fanzhh L196-212 的
#   「后台 watch_events & + 前台主循环每 60s 用挂钟 date +%s 独立判到点更新」。
#   缺这一半 → 设备停在 Active/GUI（如刚点完 KUAL 5）时收不到 readyToSuspend、
#   启动兜底闹钟在该态又被 powerd 拒绝，进程便永久卡死：11-08 09/10 点睡死、
#   11-09 00:40 零活动（ntfy 铁证）均此因。本次补齐双进程，仍逐条照抄源码。
# 现架构（= fanzhh dash-daemon.sh 完整写法）：
#   * 【前台主循环·核心保障】每 POLL=60s 用挂钟 now-last >= INTERVAL 独立触发更新，
#     完全不依赖 RTC 闹钟 / powerd 事件；sleep 被 suspend 冻结也不影响（醒来按挂钟判定）。
#   * 【后台 watch_events】-m 常驻 + 管道 while read + 外层 while true 断线重连；
#     readyToSuspend 设闹钟+关 WiFi、wakeupFromSuspend 更新+兜底设闹钟、goingToScreenSaver 设闹钟。
#   * 两路用 mkdir 原子锁 /tmp/ss_updating 去重，避免并发取图 / 重复 eips。
#   * 设闹钟只用 lipc rtcWakeup 相对秒（连设 4 次、不防抖）；绝不写 sysfs wakealarm、
#     不调 preventScreenSaver、不自己 echo mem、事件回调零网络 I/O。
#   * 计时一律挂钟 date +%s，绝不用 sleep 累计（BusyBox sleep 休眠时被冻结）。
# 【保留的 11/8 新需求】SS_SLOT_MINUTES="0 20 40"（每 20 分钟）→ 主循环 INTERVAL
#   由槽位数推出 = 3600/3 = 1200s；闹钟相对秒数由 secs_to_next_slot() 算。
#   真实分钟时间戳 ss_HH_MM.png、强制 eips、电量上报在 ss_update_once.sh / render 侧。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

# 脚本版本号：每次实质改动都 +1，供 deploy_v5.sh 自证遥测 grep 确认设备上跑的是哪一版。
SVER="20261109.2"

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

# 【2026-11-09】遥测改为纯本地日志，零网络 I/O。
# 原实现在此做 3 次 lipc-get-prop + curl -m 5 POST ntfy；放进 readyToSuspend 回调会阻塞
# 最多 5 秒，而 powerd 在该窗口故意连发多次 readyToSuspend（Basti189 L259-263 原文）。
# upstream 三家的事件回调里都只有 lipc-set-prop、零网络。版本自证由 deploy_v5.sh 的
# dep_report（独立 ntfy 通道）负责，不依赖本函数。
dbg() { echo "[$(date +'%m-%d %H:%M:%S')] [dbg] $*" >> "$SS_LOG" 2>/dev/null; }

do_update() {
    log "---- 开始更新 ----"
    T0=$(date +%s)
    # SS_FORCE_EIPS=1：保留 11/8 ca20876 真机验证过的修复。唤醒瞬间 status 常为 Active，
    # 旧逻辑会跳过 eips，导致「取图成功但屏保不刷新」。自动更新一律强制写帧缓冲；
    # 手动 KUAL「2 立即更新」直接调 ss_update_once.sh、不经此处，保持旧行为不打扰用户。
    SS_FORCE_EIPS=1 /bin/sh "$RUN_DIR/ss_update_once.sh" >> "$SS_LOG" 2>&1
    log "---- 更新结束 用时 $(( $(date +%s) - T0 ))s ----"
}

# 基于 SS_HOURS（阶段1 用，小时）算距下次更新的秒数。
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

# 基于 SS_SLOT_MINUTES（每小时内的分钟槽位，如 "0 20 40"）算距下次唤醒的秒数。
# SS_SLOT_MINUTES 是「小时内的分钟」，不再乘 60；NEXT 也以分钟计，乘以 60 得秒。
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
        # do_update 统一注入 SS_FORCE_EIPS=1：开机时 GUI 活跃(status=Active) 会被
        # ss_update_once.sh 跳过 eips，必须强制写帧缓冲，否则挂起后双稳态保留旧画面。
        do_update
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

# ---- 阶段2：RTC 真深睡（11/7 实证基线 + upstream 校核）----
set_rtc_wakeup() {
    # 严格沿用 11/7 实证基线 + 三份 upstream 源码：
    #   * 只用 lipc-set-prop -i com.lab126.powerd rtcWakeup <相对秒>
    #   * 绝不写 /sys/class/rtc/*/wakealarm（见文件头 ③，fanzhh L9-11 已证伪）
    #   * 每轮 readyToSuspend 必设、不做防抖（Basti189 L259-263：加了防抖会 "completely
    #     broke wakeups"，因为 powerd 故意重复发 readyToSuspend）
    #   * 连设 4 次（fanzhh L93-104 的重试），确保真正挂起前那次带上闹钟
    #   * 相对秒数由 secs_to_next_slot() 用挂钟算（BusyBox sleep 休眠时冻结，绝不用来计时）
    SECS=$(secs_to_next_slot)
    I=0
    while [ "$I" -lt 4 ]; do
        lipc-set-prop -i com.lab126.powerd rtcWakeup "$SECS" 2>/dev/null
        I=$(( I + 1 ))
    done
    log "rtcWakeup=${SECS}s（下次槽位，连设4次）"
}

# ---- 阶段2：严格照抄 fanzhh 双进程架构（2026-11-09 00:4x 补齐缺失的一半）----
# fanzhh/kindle-calendar-weather dash-daemon.sh L175-212 是「Kindle 7 实机验证每小时
# 真深睡唤醒」的**完整**写法，由两条互不依赖的进程组成：
#   * watch_events &  （L175-183 / L196-198）后台：-m 常驻监听 + 管道 while read
#     + 外层 while true 断线重连；只负责「readyToSuspend 设闹钟/关 WiFi」
#     与「wakeupFromSuspend 醒来更新」。
#   * 前台主循环（L200-212）：每 POLL=60s 用挂钟 date +%s 判断
#     now-last >= INTERVAL 就**独立触发一次更新**。
#     ★ 这一条才是「到点必更新、永不睡死」的真正保障：完全不依赖 RTC 闹钟、
#       不依赖任何 powerd 事件。设备没真深睡（Active/GUI/屏保但被 KUAL 拉起）时
#       照常按挂钟更新；设备真深睡时 sleep 被冻结，改由 RTC 唤醒 + 事件回调更新，
#       醒来后 SS_LAST 已刷新，主循环不会重复。两者互补覆盖所有电源状态。
# 【2026-11-09 00:40 实证】11/7 基线(894d0a6) 与 11/8 全部版本都只有
#   「单进程无限阻塞等事件」这一半：用户点完 KUAL 5 后设备停在 Active/GUI 态，
#   没有 readyToSuspend 事件、启动兜底闹钟在非 readyToSuspend 态又被 powerd 拒绝，
#   进程便永远卡在 lipc-wait-event 里 → 00:40 槽位设备零活动（ntfy 铁证）。
#   11-08 09:00/10:00「整点全不醒」也是同一根因。本次把缺的这一半补齐。
try_update() {
    # 原子锁（mkdir）：主循环与事件回调可能同时到点，避免并发取图 / 重复 eips。
    # 用目录而非文件，mkdir 在 ash 下是原子的；启动时 rm -rf 清理残留。
    if mkdir /tmp/ss_updating 2>/dev/null; then
        do_update
        rmdir /tmp/ss_updating 2>/dev/null
    else
        log "已有更新进行中，跳过本轮"
    fi
}

handle_event() {
    case "$1" in
        *readyToSuspend*)
            # 【严格约束】此回调内除 lipc-set-prop + 本地日志外不做任何网络 I/O；
            # upstream 三家均如此（fanzhh L106-111、Basti189 L289）。
            set_rtc_wakeup
            lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
            log "readyToSuspend：设闹钟 + 关 WiFi，进入深睡"
            ;;
        *wakeupFromSuspend*)
            # 被 RTC 唤醒：防更新途中被重新挂起 → 取图 → 刷屏 → 再兜底设闹钟。
            lipc-set-prop -i com.lab126.powerd deferSuspend 180 2>/dev/null
            log "RTC 唤醒 → 取图刷屏"
            try_update
            # 立刻解除 deferSuspend（对齐 zpetterd scheduler.sh L139/L157），
            # 别把「推迟挂起」撑到下一次闹钟过期。
            lipc-set-prop -i com.lab126.powerd deferSuspend 0 2>/dev/null
            set_rtc_wakeup
            lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
            log "唤醒后已兜底设下次闹钟并关 WiFi"
            ;;
        *goingToScreenSaver*)
            set_rtc_wakeup
            log "进入屏保，已设下次唤醒"
            ;;
    esac
}

watch_events() {
    while true; do
        # -m 常驻 + 管道逐行读（fanzhh L177-180）；外层 while true 是断线重连
        # （fanzhh L176/L181），而不是改用 -s 单发 —— 11/8 那次「诊断对一半、解法错」。
        lipc-wait-event -m com.lab126.powerd \
            'goingToScreenSaver,wakeupFromSuspend,readyToSuspend' 2>/dev/null \
            | while read -r EV; do
                [ -n "$EV" ] && handle_event "$EV"
              done
        log "事件监听断开，5s 后重连"
        sleep 5
    done
}

phase2_loop() {
    log "===== 阶段2（fanzhh 双进程：后台事件 + 前台挂钟轮询, SS_RTC=$SS_RTC）====="
    dbg "BOOT v$SVER phase2 rtc=$SS_RTC"
    # 清除 11/8 方案B 残留的 preventScreenSaver=1（该标志进程被杀后仍持久，
    # 不复位会禁用「按电源键进待机」）。本方案从不设置它，仅做一次性清理。
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    rm -rf /tmp/ss_updating 2>/dev/null
    startup_refresh_if_stale
    set_rtc_wakeup
    log "启动已兜底设下次唤醒闹钟"

    # 后台事件监听（fanzhh L196-198）
    watch_events &
    WATCHER=$!
    trap 'kill "$WATCHER" 2>/dev/null' EXIT INT TERM

    # 前台主循环（fanzhh L200-212）：挂钟判断，与事件完全解耦。
    # INTERVAL 由槽位数推出：当前 SS_SLOT_MINUTES="0 20 40" 共 3 槽 → 3600/3=1200s。
    SLOT_COUNT=0
    for s in $SS_SLOT_MINUTES; do SLOT_COUNT=$(( SLOT_COUNT + 1 )); done
    [ "$SLOT_COUNT" -lt 1 ] && SLOT_COUNT=1
    INTERVAL=$(( 3600 / SLOT_COUNT ))
    log "主循环启动：POLL=60s，INTERVAL=${INTERVAL}s（槽位 ${SS_SLOT_MINUTES}）"
    while true; do
        NOW=$(date +%s)
        LAST=$(cat "$SS_LAST" 2>/dev/null)
        case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
        if [ $(( NOW - LAST )) -ge "$INTERVAL" ]; then
            log "主循环：距上次更新 $(( NOW - LAST ))s >= ${INTERVAL}s → 触发更新"
            try_update
        fi
        # 挂钟判断，故 sleep 被 suspend 冻结也不影响正确性；醒来后按 SS_LAST 判定。
        sleep 60
    done
}

# ---- 入口：按 SS_RTC 分流 ----
if [ "${SS_RTC:-0}" = "1" ]; then
    phase2_loop
else
    phase1_loop
fi
