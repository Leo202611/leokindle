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
# 现架构（= 11/7 基线 = upstream 实证写法）：
#   * 无限阻塞等单个事件（不带 -s/-m），每轮重建连接，天然抗 suspend/resume 断连；
#     计时一律用挂钟 date +%s，绝不用 sleep 累计（BusyBox sleep 休眠时被冻结）。
#   * readyToSuspend：每轮必设 lipc rtcWakeup（连设 4 次、不做防抖）+ 关 WiFi 进深睡。
#   * wakeupFromSuspend：deferSuspend 防更新途中被挂起 → 取图刷屏 → 立刻 deferSuspend 0
#     → 兜底再设一次闹钟 + 关 WiFi，形成「唤醒→顺手设下一次」自闭环，单点漏设不级联。
#   * goingToScreenSaver / 启动：各兜底设一次闹钟，堵住「设备已挂起时才拉起进程」的空窗。
#   * 绝不写 sysfs wakealarm、不调 preventScreenSaver、不自己 echo mem、事件回调零网络 I/O。
# 【唯一保留的 11/8 新需求】闹钟相对秒数改由 secs_to_next_slot() 按 SS_SLOT_MINUTES
#   （当前 "0 20 40" = 每 20 分钟）计算；真实分钟时间戳 ss_HH_MM.png、强制 eips、
#   电量搭车上报都在 ss_update_once.sh / render 侧，不属本文件改动范围。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

# 脚本版本号：每次实质改动都 +1，供 deploy_v5.sh 自证遥测 grep 确认设备上跑的是哪一版。
SVER="20261109.1"

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

phase2_loop() {
    log "===== 阶段2 RTC 真深睡（11/7 实证基线 + upstream 校核, SS_RTC=$SS_RTC）====="
    dbg "BOOT v$SVER phase2 rtc=$SS_RTC"
    # 清除 11/8 方案B 残留的 preventScreenSaver=1（该标志进程被杀后仍持久，
    # 不复位会禁用「按电源键进待机」）。本方案从不设置它，仅做一次性清理。
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    rm -f /tmp/ss_updating
    startup_refresh_if_stale
    # 【兜底·关键】启动时无论如何先设一次闹钟。若进程是在设备已处于挂起态时被拉起
    # （KUAL 在线更新 / 重启守护），挂起事件不会再次触发，仅靠事件补设会留空窗。
    set_rtc_wakeup
    log "启动已兜底设下次唤醒闹钟"
    while true; do
        # 无限阻塞等下一个 powerd 事件；不用 -s 超时（suspend 期 CLOCK_MONOTONIC 冻结，
        # 超时永不返回 —— 这正是 11/8 睡死的机制）。每轮重建连接，天然抗断连。
        EV=$(lipc-wait-event com.lab126.powerd \
                'goingToScreenSaver,wakeupFromSuspend,readyToSuspend' 2>/dev/null)
        # 空返回（lipc 异常 / 连接被丢）保护：短暂等待后重建监听，避免忙循环空转耗电
        if [ -z "$EV" ]; then
            sleep 5
            continue
        fi
        case "$EV" in
            *readyToSuspend*)
                # 即将休眠：设下次 RTC 唤醒闹钟 + 关 WiFi 进入真深睡省电。
                # 【严格约束】此回调内除 lipc-set-prop 外不做任何网络 I/O / 日志外发，
                # upstream 三家均如此（fanzhh L106-111、Basti189 L289）。
                set_rtc_wakeup
                lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
                log "设唤醒闹钟并关 WiFi，进入深睡"
                ;;
            *wakeupFromSuspend*)
                # 被 RTC 唤醒：防更新途中被重新挂起 → 恢复 WiFi → 取图 → 刷屏。
                # ss_update_once.sh 内部会按需开 WiFi（wifi_restore），故此处只需 deferSuspend。
                lipc-set-prop -i com.lab126.powerd deferSuspend 180 2>/dev/null
                log "RTC 唤醒，开始恢复 WiFi 并取图"
                do_update
                dbg "WAKE upd done"
                # 更新一结束立刻解除 deferSuspend（对齐 zpetterd scheduler.sh L139/L157），
                # 让设备立即回到可挂起态，别把「推迟挂起」撑到闹钟过期。
                lipc-set-prop -i com.lab126.powerd deferSuspend 0 2>/dev/null
                # 【兜底·关键】无论本次取图成功与否，唤醒后主动再设一次闹钟并关 WiFi。
                # 与 readyToSuspend 的补设互为冗余：「唤醒→顺手设下一次」自成闭环，
                # 单点漏设不再级联成永久睡死（11/7 基线核心）。
                set_rtc_wakeup
                lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
                log "唤醒后已兜底设下次闹钟并关 WiFi"
                ;;
            *goingToScreenSaver*)
                # 手动按电源进待机（非 RTC 唤醒）：确保下次休眠带唤醒闹钟
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
