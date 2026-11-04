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
# 2026-11-04 用户定案：6/9/12/15/18 共 5 次，比原 4 次方案多 1 次；
# 夜间 18:00 -> 次日 6:00 完全不唤醒，是整机最省电的一段。
SS_HOURS="6 9 12 15 18"

# 图源。默认只走公网，因为 Kindle 与 Mac 常不在同一 WiFi。
# 留空即可避免为了连不上的电脑白等一个超时。
SS_LOCAL_SRV=""
SS_GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
SS_GH_BRANCH="dash"
SS_CDN="https://cdn.jsdelivr.net/gh/Leo202611/leokindle@dash"

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
SS_RTC=0

[ -f /mnt/us/dash/ss_config.local ] && . /mnt/us/dash/ss_config.local
