#!/bin/sh
# Kindle 仪表盘 · KUAL「在线更新(WiFi)」入口
#
# 目的：用户只有 KUAL 菜单、没有终端，设备也没有入站 SSH/HTTP 端口。
# 只要某一刻通过 wifi_push.sh 把 v5 装进去一次，之后所有脚本/图片/菜单
# 的更新都可以在 KUAL 里点一下完成，全程 WiFi，不需要电脑、不需要敲命令。
#
# 流程：
#   1) 从「电脑 HTTP -> GitHub main」拉最新 deploy_v5.sh 到 /tmp
#   2) 管道外的 /tmp 副本执行安装（只安装、不启动）
#   3) 用 restart 模式重启守护进程，保持当前横竖屏，让新代码生效
#
# 关键点：install 会覆盖本脚本自身，因此必须先把安装器放到 /tmp 再执行；
# deploy_v5.sh 安装 KUAL 入口时用的是 tmp + mv（替换目录项），
# 正在运行的本脚本仍持有旧 inode，不会被截断写坏。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH
LOG=/mnt/us/dash/update.log
SRV="${DASH_SRV:-192.168.110.46:8899}"
GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
TMP=/tmp/dash_deploy_wifi.sh
ENTRY=/mnt/us/extensions/dash/bin/dash_on_v5.sh

say() {
    echo "[$(date +"%m-%d %H:%M:%S")] $*" >> "$LOG" 2>/dev/null
    echo "$*"
}

shebang_ok() {
    [ -s "$1" ] && head -c 60 "$1" | grep -q '#!/bin/sh'
}

say "===== 在线更新开始（全程 WiFi）====="
rm -f "$TMP"

# 电脑与 Kindle 常不在同一 WiFi：本地源只给 4 秒，别让用户干等 30 秒。
if curl -sL -m 4 -o "$TMP" "http://$SRV/deploy_v5.sh" 2>/dev/null && shebang_ok "$TMP"; then
    say "安装器来源: 电脑 HTTP ($SRV)"
# -k：Kindle 8 固件 CA 证书较旧，HTTPS 常失败；这里只取公开脚本，无密钥。
elif curl -sLk -m 40 -H "Accept: application/vnd.github.raw" \
        -o "$TMP" "$GH_API/deploy_v5.sh?ref=main" 2>/dev/null && shebang_ok "$TMP"; then
    say "安装器来源: GitHub main"
else
    say "两个来源都拿不到 deploy_v5.sh，放弃更新（旧版继续正常运行）"
    rm -f "$TMP"
    exit 1
fi

# 只安装不启动：不带参数时 deploy_v5.sh 不会碰正在运行的实例。
sh "$TMP" >> "$LOG" 2>&1
RC=$?
rm -f "$TMP"
say "安装器返回码: $RC"

if [ ! -s "$ENTRY" ]; then
    say "启动入口缺失，更新中止"
    exit 1
fi

# 【重要】不能无条件重启常亮仪表盘守护进程。
# B 方案（linkss 屏保）下 dashd 的 keep_awake() 会阻止休眠，屏保永远不会出现。
# 所以只重启「当前真正启用的那一种模式」；两种都没启用就只更新文件。
if [ -f /mnt/us/dash/ss_enabled ]; then
    say "已启用待机画面定时更新 -> 重装并重启屏保调度服务"
    sh /mnt/us/extensions/dash/bin/ss_enable.sh >> "$LOG" 2>&1
else
    DPID=$(cat /var/local/dashd.pid 2>/dev/null)
    if [ -n "$DPID" ] && [ -d "/proc/$DPID" ]; then
        say "常亮仪表盘在运行 -> restart 保持版式重启"
        sh "$ENTRY" restart >> "$LOG" 2>&1
    else
        say "两种模式都未启用，只更新文件，不启动任何守护进程"
    fi
fi
sleep 6
say "当前版式: $(cat /mnt/us/dash/orient 2>/dev/null)"
say "屏保日志尾部:"
tail -8 /mnt/us/dash/ss.log 2>/dev/null | sed 's/^/  /'
say "更新日志尾部:"
tail -8 "$LOG" 2>/dev/null | sed 's/^/  /'
say "===== 在线更新完成 ====="
exit 0
