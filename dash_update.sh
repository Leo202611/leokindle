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

if curl -sL -m 30 -o "$TMP" "http://$SRV/deploy_v5.sh" 2>/dev/null && shebang_ok "$TMP"; then
    say "安装器来源: 电脑 HTTP ($SRV)"
elif curl -sL -m 40 -H "Accept: application/vnd.github.raw" \
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

# restart 保持版式强制重启，新版守护进程才会被加载。
sh "$ENTRY" restart >> "$LOG" 2>&1
sleep 6
say "当前版式: $(cat /mnt/us/dash/orient 2>/dev/null)"
say "守护日志尾部:"
tail -8 "$LOG" 2>/dev/null | sed 's/^/  /'
say "===== 在线更新完成 ====="
exit 0
