#!/bin/sh
# KUAL 入口：以【竖屏】启动仪表盘（默认版式）
#
# 走 dash_on_v5.sh port：写 orient=p，并强制重启实例。
if [ -f /mnt/us/dash/dash_on_v5.sh ]; then
    exec sh /mnt/us/dash/dash_on_v5.sh port
fi
exec sh /mnt/us/extensions/dash/bin/dash_on_v5.sh port
