#!/bin/sh
# KUAL「停用定时更新」：停服务、清 RTC 闹钟、移除自启
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
D=/mnt/us/dash
LOG=/mnt/us/dash/ss_enable.log
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; echo "$*"; }

say "===== 停用待机画面定时更新 ====="
stop dashss >/dev/null 2>&1 && say "已 stop dashss" || say "dashss 未在运行"
pkill -f 'ss_scheduler.sh' 2>/dev/null
pkill -f 'ss_update_once.sh' 2>/dev/null

if [ -f /etc/upstart/dashss.conf ]; then
    mntroot rw >/dev/null 2>&1
    rm -f /etc/upstart/dashss.conf 2>/dev/null
    mntroot ro >/dev/null 2>&1
    say "已移除开机自启配置"
fi

# 清掉可能已经设好的唤醒闹钟，否则设备仍会按点醒来
echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
rm -f "$D/ss_enabled" 2>/dev/null
rm -rf /tmp/dashss /tmp/dashss.conf 2>/dev/null

# 【2026-11-05】写「禁止自动启用」标记：
# deploy_v5.sh 末尾默认会在在线更新后自动启用屏保服务，若不停掉，
# 用户为了拿修复而点一次「在线更新(WiFi)」又会把服务拉起来，
# 想观察设备是否稳定就没法做 A/B 对照了。
# 想重新启用：手动点菜单第 1 项「启用定时更新」，它会删掉本标记。
echo "$(date +'%m-%d %H:%M:%S') 手动停用" > "$D/ss_no_auto"
say "已写 ss_no_auto：之后点「在线更新(WiFi)」只装文件，不会自动重启服务"
say "完成。此后不再自动唤醒；屏保仍显示最后一次的图片（静态，零耗电）"
say "想恢复自动更新：手动点菜单第 1 项「启用定时更新(6/9/12/15/18)」"
exit 0
