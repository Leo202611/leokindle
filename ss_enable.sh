#!/bin/sh
# KUAL「启用定时更新(每整点)」：装 upstart 服务 + 立刻刷新一次画面
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

# 1) 常亮仪表盘与屏保互斥：dashd 的 keep_awake() 会阻止休眠，屏保永远不会出现。
#    这里不调用旧版 dash_off.sh —— 它会 initctl start lab126_gui，在 KUAL 动作里
#    动 GUI 可能把菜单自己关掉，导致后面的启用步骤跑不完。只精确停守护进程。
touch /var/local/dash_stop 2>/dev/null
DPID=$(cat /var/local/dashd.pid 2>/dev/null)
if [ -n "$DPID" ] && [ -d "/proc/$DPID" ]; then
    kill "$DPID" 2>/dev/null
    say "已停止常亮仪表盘 pid=${DPID}"
fi
sleep 1
pkill -f 'dashd.*\.sh' 2>/dev/null
rm -f /var/local/dash_stop /var/local/dashd.pid 2>/dev/null
say "常亮守护已清理（未改 GUI）"

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

# 3) 不在 KUAL 动作里同步下载图片。
#    在线更新链路里本脚本会被连续调用两次（deploy_v5.sh 自动启用 +
#    设备 1a18728 版 dash_update.sh 在 ss_enabled 存在时的重复启用），
#    同步刷图会把菜单动作拖到 60 秒并多唤醒取一次图。
#    统一交给调度器启动时的「启动补刷」（ss_last 为空或超过 20 分钟即执行），
#    它在 upstart 服务里后台跑，不会卡住 KUAL。
#    需要立刻刷新请用菜单第 2 项「立即更新待机画面(WiFi)」。
#    quick 参数保留只为兼容旧调用，行为一致。
if [ -f "$RUN/ss_scheduler.sh" ]; then
    say "刷图交由调度器启动补刷；菜单第 2 项可手动立即刷新"
else
    say "WARN 缺 ss_scheduler.sh，启动补刷不可用"
fi

# 4) 注册 upstart 自启（rootfs 默认只读，需 mntroot rw）
# 【2026-11-05 修复】/tmp 是 tmpfs，重启即清空。原来只在启用时把脚本复制进
# /tmp/dashss，开机时 upstart 按 start on started lab126_gui 拉起服务却找不到
# 脚本，重启后定时更新就悄悄失效了。加 pre-start，每次服务启动都从
# /mnt/us/dash 重新复制一次，重启可自愈。
cat > /tmp/dashss.conf <<'CONF'
start on started lab126_gui
stop on stopping lab126_gui
respawn
respawn limit 3 300
pre-start script
    mkdir -p /tmp/dashss
    cp /mnt/us/dash/ss_config.sh /tmp/dashss/ 2>/dev/null
    cp /mnt/us/dash/ss_update_once.sh /tmp/dashss/ 2>/dev/null
    cp /mnt/us/dash/ss_scheduler.sh /tmp/dashss/ 2>/dev/null
    chmod 755 /tmp/dashss/*.sh 2>/dev/null
    test -f /tmp/dashss/ss_scheduler.sh || exit 1
end script
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

# 5) 标记：dash_update.sh 在线更新后据此重启屏保服务而非常亮守护进程。
#    内容写清启动方式，以后读日志能判断服务是否真的起来了。
MODE="upstart"
if ! initctl status dashss 2>/dev/null | grep -q 'running'; then
    MODE="setsid(重启后需重新点一次)"
fi
echo "$(date +'%m-%d %H:%M:%S') mode=$MODE" > "$D/ss_enabled"
# 手动启用即表示用户同意自动模式，撤掉「停用」时写的禁止自动启用标记
rm -f "$D/ss_no_auto" 2>/dev/null
say "服务状态: ${MODE}"

if [ ! -d /mnt/us/linkss/screensavers ]; then
    say "WARN 未检测到 linkss：请先 KUAL/Helper/Install MR Packages（或 ;log mrpi）安装屏保 hack"
    say "     装好后再点一次「启用」，休眠时才会显示自定义待机画面"
fi
say "完成。按电源键休眠即可验收；日志 $D/ss.log"
exit 0
