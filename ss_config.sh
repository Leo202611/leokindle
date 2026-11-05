#!/bin/sh
# 待机画面（linkss 屏保）定时更新 · 共享配置
#
# 所有脚本都从 /mnt/us/dash/ss_config.sh 读取本文件。
# 想改更新频率、图源或超时，不要改本文件（在线更新会覆盖），
# 而是在 /mnt/us/dash/ss_config.local 里写覆盖项，例如：
#   SS_HOURS="6 9 12 15 18"      -> 每天 5 次（当前默认，性价比方案）
#   SS_HOURS="0 6 9 12 18"       -> 同样 5 次，但保留 0 点唤醒
#   SS_HOURS="0 6 12 18"         -> 每天 4 次（最省电）
#   SS_HOURS="0 1 2 ... 23"      -> 每小时（耗电明显增加，见项目说明）
#   SS_LOCAL_SRV="192.168.x.x:8899" -> 同网时优先用电脑 HTTP
# deploy_v5.sh 不会下发、也不会覆盖 ss_config.local。

# 每天自动更新的整点（本地时间）。
# 2026-11-05 用户改为每个整点更新（0–23 共 24 次）：待机画面每小时刷新一次。
# 配合阶段2 真·深睡 RTC 唤醒可实现"每小时唤醒一次、其余时间深睡"的周级续航；
# 阶段1（deferSuspend 不深睡）下每小时唤醒耗电略高于 5 次/日，但仍远未到逐分钟级。
SS_HOURS="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23"

# 每隔 N 分钟更新一次（>0 启用高频测试模式）；生产期设为 0，
# 恢复按 SS_HOURS 整点更新（每天每整点共 24 次）。
# 2026-11-05 12:00 验证全自动通过，已由测试期 20 切回生产 0。
SS_TEST_INTERVAL="0"

# 图源。默认只走公网，因为 Kindle 与 Mac 常不在同一 WiFi。
# 留空即可避免为了连不上的电脑白等一个超时。
SS_LOCAL_SRV=""
SS_GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
SS_GH_BRANCH="dash"
# gcore.jsdelivr.net 是 workflow 自己用的备用通道，实测可取到 600x800 L 槽位图；
# cdn.jsdelivr.net 在部分网络下 SSL 握手失败，不作为主备用。
SS_CDN="https://gcore.jsdelivr.net/gh/Leo202611/leokindle@dash"
SS_RAW="https://raw.githubusercontent.com/Leo202611/leokindle/dash"
# Kindle 8 固件 CA 证书较旧，HTTPS 常失败（电量上报链路已踩过这个坑）。
# 这些图都是公开静态资源、无密钥，默认允许 curl -k；设 0 可恢复严格校验。
SS_INSECURE=1

# linkss 屏保目录与文件名（源码 shuffless 要求小写 .png + bg_ssNN 命名）
SS_LINK_DIR="/mnt/us/linkss/screensavers"
SS_BK_DIR="/mnt/us/linkss/backup_custom"
SS_FILE="bg_ss00.png"

# 本地状态文件
SS_DST_DIR="/mnt/us/dash"
SS_LOG="/mnt/us/dash/ss.log"
SS_LAST="/mnt/us/dash/ss_last"
SS_DONE="/mnt/us/dash/ss_done"
SS_FLAG="/mnt/us/dash/ss_enabled"

# 省电硬约束：单次唤醒总预算，超时即放弃，不重试，等下一个更新点。
SS_CURL_T=20
SS_WIFI_WAIT=20
SS_UPDATE_TIMEOUT=60
# 阶段2 开关：1=启用 RTC 真深睡（监听 powerd 事件、readyToSuspend 里设 rtcWakeup、
# 唤醒后取图刷屏再睡，目标不接电源撑一周）；0=阶段1 轻休眠（回退兜底，续航 1–2 天）。
# 【2026-11-05 默认改为 1】新部署默认走阶段2 深睡；若真机实测整点不更新/不唤醒，
# 在 /mnt/us/dash/ss_config.local 写 SS_RTC=0 并 KUAL「在线更新→停用→启用」，或点
# KUAL「11 阶段2深睡:关」即退回阶段1（每小时仍自动换图，续航 1–2 天）。
# 注：ss_config.local 里的 SS_RTC 会覆盖本默认值（deploy 不覆盖 local）。
SS_RTC=1

# 唤醒后 WiFi 恢复（阶段2 深睡后必需）：
# 5.16.x 休眠后 WiFi 在 suspended 态无法程序重连（koreader 5.18.6 / fanzhh 均已确认）。
# 纯静默模式的总预算（秒）；fanzhh 实测需给到 ~150s 才稳（15s/30s 两段偶发失败）。
SS_WIFI_RESTORE_T="${SS_WIFI_RESTORE_T:-150}"
# dance 开启时，静默只做这么久的快速试探就转 dance。本固件实测静默基本连不上，
# 白等 150s 会让每次唤醒多 active 两分半（24 次/天 ≈ 1h/天），直接拖垮周级续航。
SS_WIFI_SILENT_T="${SS_WIFI_SILENT_T:-15}"
# 「模拟电源键」dance：toggleSuspend 强制 active 后 WiFi 约 3s 连通。
# 【2026-11-06 真机验证】Kindle 8 / 5.16.2.1.1 + linkss：
#   SS_WIFI_DANCE=0（纯静默）-> 00:00 整点不更新，画面滞留前一日 23:00；
#   SS_WIFI_DANCE=1          -> 01:00 整点自动更新成功，全程无人工干预。
# 故本固件把 dance 设为默认开（1）：干净部署即可开箱使用阶段2 深睡。
# KUAL「13」会写 SS_WIFI_DANCE=0 关掉它，一般不推荐。
SS_WIFI_DANCE="${SS_WIFI_DANCE:-1}"

[ -f /mnt/us/dash/ss_config.local ] && . /mnt/us/dash/ss_config.local

# 唤醒后恢复 WiFi（阶段2 深睡后必需）。返回 0=已连通。
# 背景：5.16.x 设备 suspend 后 WiFi 断且 suspended 态无法静默重连
#   （koreader-live-sleepscreen FW5.18.6 实测：所有静默手段全失败）。
# 【2026-11-06 真机修正】fanzhh 在 5.11.1.1 上「静默 8/8 成功」不能外推到 5.16.x：
#   咱 Kindle 8 虽是 i.MX，静默仍失败（00:00 不更新），必须 toggleSuspend dance（01:00 才通）。
#   故保留静默仅作 15s 快速试探，主力是 dance。
wifi_restore() {
    ST=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    [ "$ST" = "CONNECTED" ] && return 0
    log "wifi_restore: 当前 $ST，开始重连"
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    lipc-set-prop com.lab126.wifid enable 1 2>/dev/null
    # dance 开时静默只快速试探 SS_WIFI_SILENT_T 秒即转 dance（省电）；
    # 纯静默模式仍用完整 SS_WIFI_RESTORE_T 预算。
    I=0
    if [ "${SS_WIFI_DANCE:-1}" = "1" ]; then
        MAX=${SS_WIFI_SILENT_T:-15}
    else
        MAX=${SS_WIFI_RESTORE_T:-150}
    fi
    while [ "$I" -lt "$MAX" ]; do
        ST=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        [ "$ST" = "CONNECTED" ] && { log "wifi_restore: 静默重连成功(${I}s)"; return 0; }
        # 主动触发一次关联 + 兜底 DHCP
        lipc-send-event com.lab126.cmd ensureConnection "wifi:" 2>/dev/null
        /sbin/udhcpc -n -q 2>/dev/null
        sleep 5
        I=$(( I + 5 ))
    done
    if [ "${SS_WIFI_DANCE:-1}" = "1" ]; then
        log "wifi_restore: 静默试探未成，尝试 toggleSuspend 模拟电源键"
        lipc-send-event com.lab126.powerd toggleSuspend 2>/dev/null
        I=0
        while [ "$I" -lt 30 ]; do
            ST=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
            [ "$ST" = "CONNECTED" ] && { log "wifi_restore: dance 后连通(${I}s)"; return 0; }
            sleep 3
            I=$(( I + 3 ))
        done
    fi
    log "wifi_restore: 失败（WiFi 仍 $ST）"
    return 1
}
