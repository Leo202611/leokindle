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
say "完成。此后不再自动唤醒；屏保仍显示最后一次的图片（静态，零耗电）"
exit 0
