#!/bin/sh
# Kindle 仪表盘 · 关闭脚本（KUAL 扩展版）
#
# 关键点：
#   1) 先写停止标记，让守护进程走正常退出路径（走 trap -> 恢复 GUI）。
#   2) 再按 PID 精确 kill。注意不要用 killall dashd.sh 一把梭：
#      那样会连看门狗一起杀，而且强杀时 trap 可能来不及跑，
#      结果 GUI 停在停止状态，Kindle 黑屏且触摸无响应。
#   3) 最后无条件恢复 GUI，保证一定能回到 Kindle 界面。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

LOG=/mnt/us/dash/dashd.log
log() { echo "[$(date +"%m-%d %H:%M:%S")] $*" >> "$LOG"; }

touch /var/local/dash_stop

PID=$(cat /var/local/dashd.pid 2>/dev/null)
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    log "dash_off: 停止实例 pid=$PID"
    kill "$PID" 2>/dev/null
else
    log "dash_off: 无运行实例"
fi

sleep 2

# 无条件恢复 GUI
initctl start lab126_gui >> "$LOG" 2>&1 || start lab126_gui >> "$LOG" 2>&1
rm -f /var/local/dashd.pid
sync
exit 0
