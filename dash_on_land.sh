#!/bin/sh
# KUAL 入口：以【横屏】启动仪表盘
#
# 重要：Kindle 8 (2016) 的物理屏是 600x800 竖屏，不能物理旋转，也没有陀螺仪。
# 「横屏」是把 800x600 的画布逆时针旋转 90 度后烧进 600x800 帧缓冲，
# 屏幕本身不会转。启动后请把 Kindle 横过来（顺时针转 90 度）观看。
#
# 走 dash_on_v5.sh land：写 orient=l，并强制重启实例
# （守护进程把版式缓存在内存里，只改文件不重启是不生效的）。
if [ -f /mnt/us/dash/dash_on_v5.sh ]; then
    exec sh /mnt/us/dash/dash_on_v5.sh land
fi
exec sh /mnt/us/extensions/dash/bin/dash_on_v5.sh land
