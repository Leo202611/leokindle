#!/bin/sh
# KUAL「启用定时更新(6/9/12/15/18)」：装 upstart 服务 + 立刻刷新一次画面
#
# 一步做完所有前置：停掉常亮仪表盘守护进程、清 linkss 多余图片、
# 拉一张新图、注册开机自启服务。用户无需终端、无需数据线。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
D=/mnt/us/dash
E=/mnt/us/extensions/dash/bin
LOG=/mnt/us/dash/ss_enable.log
RUN=/tmp/dashss
say() { echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; echo "$*"; }

say "===== 启用待机画面定时更新 ====="

# 1) 常亮仪表盘与屏保互斥：dashd 的 keep_awake() 会阻止休眠，屏保永远不会出现
if [ -f "$E/dash_off.sh" ]; then
    sh "$E/dash_off.sh" >> "$LOG" 2>&1
    say "已停止常亮仪表盘守护进程"
fi
pkill -f 'dashd.*\.sh' 2>/dev/null
rm -f /var/local/dash_stop 2>/dev/null

# 2) 运行脚本复制进 tmpfs：社区实测调度器若在 /mnt/us 上持有打开的文件句柄，
#    FAT/FUSE 卸载时会损坏簇链，进而搞坏整个 extensions 目录。
mkdir -p "$RUN" 2>/dev/null
for f in ss_config.sh ss_update_once.sh ss_scheduler.sh; do
    if [ -f "$D/$f" ]; then
        cp "$D/$f" "$RUN/$f.t" 2>/dev/null \
            && mv "$RUN/$f.t" "$RUN/$f" 2>/dev/null \
            && chmod 755 "$RUN/$f" 2>/dev/null \
            && say "装入 tmpfs: $f"
    else
        say "WARN 缺 $D/${f}（请先点「在线更新(WiFi)」）"
    fi
done

# 3) 先立刻刷新一次，用户按电源键就能看到新图（修正中午 12:00 静态图）
if [ -f "$RUN/ss_update_once.sh" ]; then
    sh "$RUN/ss_update_once.sh" >> "$LOG" 2>&1
    say "已做一次立即更新"
fi

# 4) 注册 upstart 自启（rootfs 默认只读，需 mntroot rw）
cat > /tmp/dashss.conf <<'CONF'
start on started lab126_gui
stop on stopping lab126_gui
respawn
respawn limit 5 60
exec /bin/sh /tmp/dashss/ss_scheduler.sh
CONF
if [ -d /etc/upstart ]; then
    mntroot rw >/dev/null 2>&1
    cp /tmp/dashss.conf /etc/upstart/dashss.conf 2>/dev/null
    mntroot ro >/dev/null 2>&1
    stop dashss >/dev/null 2>&1
    if start dashss >/dev/null 2>&1; then
        say "已启动开机自启服务 dashss（重启后仍生效）"
    else
        say "WARN start dashss 失败，改用 setsid 后台守护（重启后需重新点一次）"
        setsid /bin/sh "$RUN/ss_scheduler.sh" >> "$LOG" 2>&1 < /dev/null &
    fi
else
    say "WARN 无 /etc/upstart，改用 setsid 后台守护（重启后需重新点一次）"
    setsid /bin/sh "$RUN/ss_scheduler.sh" >> "$LOG" 2>&1 < /dev/null &
fi

# 5) 标记录：dash_update.sh 在线更新后据此重启屏保服务而非常亮守护进程
echo "$(date +'%m-%d %H:%M:%S')" > "$D/ss_enabled"

if [ ! -d /mnt/us/linkss/screensavers ]; then
    say "WARN 未检测到 linkss：请先 KUAL/Helper/Install MR Packages（或 ;log mrpi）安装屏保 hack"
    say "     装好后再点一次「启用」，休眠时才会显示自定义待机画面"
fi
say "完成。按电源键休眠即可验收；日志 $D/ss.log"
exit 0
