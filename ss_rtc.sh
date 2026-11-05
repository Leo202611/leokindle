#!/bin/sh
# KUAL「阶段2 深睡 RTC 开关」
#
# 在设备本地写入 /mnt/us/dash/ss_config.local 的 SS_RTC，并重启调度器使其生效。
# 用法：ss_rtc.sh 1 开（RTC 真深睡，目标续航一周）
#       ss_rtc.sh 0 关（退回阶段1 轻眠，续航 1–2 天，兜底用）
#
# 设计要点：SS_RTC 走 ss_config.local 覆盖，deploy_v5.sh / 在线更新不会动它，
# 所以这是用户侧安全开关。写完复用 ss_enable.sh 完成「停守护→拷 tmpfs→起 upstart」。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
D=/mnt/us/dash
LOCAL=$D/ss_config.local
MODE="${1:-1}"
LOG=$D/ss_rtc.log
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; echo "$*"; }

say "===== 阶段2 RTC 开关 -> SS_RTC=$MODE ====="

# 写 / 改 ss_config.local（deploy 不覆盖本文件，用户侧控制）
if [ ! -f "$LOCAL" ]; then
    { echo "# 本地覆盖配置（deploy_v5.sh 不覆盖本文件）"; echo "SS_RTC=$MODE"; } > "$LOCAL"
    say "新建 $LOCAL: SS_RTC=$MODE"
elif grep -q '^[[:space:]]*SS_RTC=' "$LOCAL"; then
    sed -i "s/^[[:space:]]*SS_RTC=.*/SS_RTC=$MODE/" "$LOCAL"
    say "更新 $LOCAL -> SS_RTC=$MODE"
else
    echo "SS_RTC=$MODE" >> "$LOCAL"
    say "追加 $LOCAL -> SS_RTC=$MODE"
fi
sync

# 重启调度器以应用新模式（复用 ss_enable.sh 的停/拷/起逻辑）
say "重启调度器以应用新模式（复用 ss_enable.sh）"
if [ -f "$D/ss_enable.sh" ]; then
    sh "$D/ss_enable.sh" >> "$LOG" 2>&1
    say "OK 已重启；当前 SS_RTC=$MODE（调度日志 $D/ss.log）"
else
    say "WARN 缺 $D/ss_enable.sh，请先点「在线更新(WiFi)」"
fi
exit 0
