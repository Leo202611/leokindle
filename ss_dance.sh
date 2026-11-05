#!/bin/sh
# KUAL「阶段2 WiFi dance 开关」
#
# 在设备本地写入 /mnt/us/dash/ss_config.local 的 SS_WIFI_DANCE，并重启调度器使其生效。
# 用法：ss_dance.sh 1 开（深睡唤醒后静默重连失败时，改用 toggleSuspend 模拟电源键强制重连）
#       ss_dance.sh 0 关（默认，纯静默重连）
#
# 背景：5.16.x 深睡后 WiFi 在 suspended 态无法静默重连；Kindle 8 是 i.MX，静默手段通常够用
# （fanzhh 在 5.11.1.1 上 8/8 成功）。只有真机实测 wifi_restore 的 150s 静默重连仍失败，
# 才需要开 dance 兜底（每次唤醒多约 10s active，仍远优于常亮）。
# 写完复用 ss_enable.sh 完成「停守护→拷 tmpfs→起 upstart」。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
D=/mnt/us/dash
LOCAL=$D/ss_config.local
MODE="${1:-1}"
LOG=$D/ss_dance.log
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; echo "$*"; }

say "===== 阶段2 WiFi dance 开关 -> SS_WIFI_DANCE=$MODE ====="

# 写 / 改 ss_config.local（deploy 不覆盖本文件，用户侧控制）
if [ ! -f "$LOCAL" ]; then
    { echo "# 本地覆盖配置（deploy_v5.sh 不覆盖本文件）"; echo "SS_WIFI_DANCE=$MODE"; } > "$LOCAL"
    say "新建 $LOCAL: SS_WIFI_DANCE=$MODE"
elif grep -q '^[[:space:]]*SS_WIFI_DANCE=' "$LOCAL"; then
    sed -i "s/^[[:space:]]*SS_WIFI_DANCE=.*/SS_WIFI_DANCE=$MODE/" "$LOCAL"
    say "更新 $LOCAL -> SS_WIFI_DANCE=$MODE"
else
    echo "SS_WIFI_DANCE=$MODE" >> "$LOCAL"
    say "追加 $LOCAL -> SS_WIFI_DANCE=$MODE"
fi
sync

# 重启调度器以应用新模式（复用 ss_enable.sh 的停/拷/起逻辑）
say "重启调度器以应用新模式（复用 ss_enable.sh）"
if [ -f "$D/ss_enable.sh" ]; then
    sh "$D/ss_enable.sh" >> "$LOG" 2>&1
    say "OK 已重启；当前 SS_WIFI_DANCE=$MODE（调度日志 $D/ss.log）"
else
    say "WARN 缺 $D/ss_enable.sh，请先点「在线更新(WiFi)」"
fi
exit 0
