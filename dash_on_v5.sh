#!/bin/sh
# Kindle 仪表盘 · 启动脚本 v5
#
# 与 v4 的差别：
#   1) 拉起 dashd_v5.sh（修了 5 个 bug：横竖屏缓存串版、版式切换后图片路径不更新、
#      看门狗重启回退旧版、GUI 冻结替代粗暴 stop、防息屏三层兜底）
#   2) 启动时用 setsid 彻底脱离 KUAL 的进程组 —— KUAL 菜单动作返回时会给子进程发 SIGHUP，
#      不脱离的话实例活不过几秒（之前反复出现"点一下就没了"）
#   3) 已有实例在跑时：不 killall，直接重绘 + 请求刷新（保留 v4 的正确行为）
#   4) 停 GUI 之前先把缓存图准备好并预热，保证"点开就有画面"
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
mkdir -p /mnt/us/dash

PID=$(cat /var/local/dashd.pid 2>/dev/null)

# 实例是否还活着：看 /proc 下有没有这个 PID 的目录。
# 不要用 `kill -0 $PID` —— Kindle 的 busybox/ash 上对早已不存在的 PID 也可能返回 0。
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    # 已有实例在跑：不要动它（killall 会触发退出路径，白白重画一次）。
    # 立刻重绘当前画面，并写刷新标记让守护进程去取新图。
    if [ -s /mnt/us/dash/cur_p.png ]; then
        eips -f -g /mnt/us/dash/cur_p.png >/dev/null 2>&1
    fi
    touch /var/local/dash_refresh
    sync
    exit 0
fi

# 没有实例在跑：清理残留进程（覆盖新旧各种脚本名）后启动一个。
# 注意 killall/pkill 的模式要覆盖所有版本，否则旧实例会和新实例抢屏幕。
killall dashd.sh 2>/dev/null
killall dashd_v3.sh 2>/dev/null
killall dashd_v4.sh 2>/dev/null
killall dashd_v4_run.sh 2>/dev/null
killall dashd_v5.sh 2>/dev/null
pkill -f 'dashd.*\.sh' 2>/dev/null
sleep 1

rm -f /var/local/dash_stop /var/local/dash_refresh /var/local/dash_rotate /var/local/dash_freeze

# setsid：新会话，彻底脱离 KUAL 的进程组与信号。
# nohup 只能挡 SIGHUP，挡不住 KUAL 退出时对整个进程组的清理。
setsid sh /mnt/us/dash/dashd_v5.sh >> /mnt/us/dash/dashd.log 2>&1 < /dev/null &
echo $! > /var/local/dashd.pid
sync
exit 0
