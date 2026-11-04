#!/bin/bash
# Mac 端：通过 WiFi 把 v5 全套装进 Kindle（不用 USB，也不用在 Kindle 上敲命令）
#
# 前提：在 KUAL 里启用 USBNetwork 的 WiFi SSH（越狱常见扩展），Kindle 开放 22 端口。
# 原理：Mac 通过 SSH 在 Kindle 上执行一条 curl，让设备自己从 Mac 的 HTTP 服务
#       拉取安装器；安装器再把全部脚本/图片/菜单经 WiFi 装进设备。
#       —— 全程 WiFi，没有任何文件走数据线。
#
# 用法：
#   ./wifi_push.sh                        # 默认 192.168.110.101 + 横屏启动
#   ./wifi_push.sh 192.168.110.101 port  # 指定 IP 与版式(start|land|port)
#   ./wifi_push.sh auto start            # auto = 按 MAC 从 ARP 表找 Kindle
set -u

DASH_DIR="/Users/leoji/WorkBuddy/2026-11-01-01-37-28/kindle/dashboard"
MACIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
IP="${1:-192.168.110.101}"
MODE="${2:-land}"

case "$MODE" in start|land|port) ;; *) echo "版式参数只能是 start|land|port"; exit 1 ;; esac

# ---- 1. 定位 Kindle ----
if [ "$IP" = "auto" ]; then
    IP=$(arp -a 2>/dev/null | grep -i '50:f5:da:ae:6d' \
         | sed -n 's/.*(\([0-9.]*\)).*/\1/p' | head -1)
    [ -z "$IP" ] && { echo "ARP 表里找不到 Kindle，请先让设备连上 WiFi"; exit 1; }
    echo "自动定位 Kindle: $IP"
fi

# ---- 2. 找 SSH 端口 ----
PORT=""
for p in 22 2222 8022 2022; do
    if nc -z -G 1 -w 1 "$IP" "$p" >/dev/null 2>&1; then PORT="$p"; break; fi
done
if [ -z "$PORT" ]; then
    echo "✗ $IP 上没有 SSH 端口（22/2222/8022/2022 全关）"
    echo ""
    echo "请先在 Kindle 的 KUAL 菜单里找下列任一项并点启用："
    echo "  · USBNetwork / USB Network"
    echo "  · WiFi SSH / Enable SSH / Dropbear"
    echo "  · 网络 → 开启 SSH"
    echo "启用后重新运行本脚本。若菜单里完全没有这类项，把 KUAL 里"
    echo "能看到的菜单项名字告诉我，我改用别的通道。"
    exit 1
fi
echo "✓ 检测到 SSH  $IP:$PORT"

# ---- 3. 确保 Mac 的 HTTP 分发服务在线 ----
if ! curl -s --noproxy '*' -m 5 -o /dev/null "http://${MACIP}:8899/deploy_v5.sh"; then
    echo "· Mac HTTP 服务未响应，尝试拉起 ..."
    ( cd "$DASH_DIR/wifi_srv" && nohup env -u HTTP_PROXY -u HTTPS_PROXY \
        -u http_proxy -u https_proxy python3 -m http.server 8899 \
        --bind 0.0.0.0 >/tmp/wifi_srv.log 2>&1 & )
    sleep 2
fi
if curl -s --noproxy '*' -m 5 -o /dev/null "http://${MACIP}:8899/deploy_v5.sh"; then
    echo "✓ Mac HTTP 在线  http://${MACIP}:8899"
else
    echo "✗ Mac HTTP 起不来，无法做 bootstrap（安装器内部的 GitHub 兜底用不上）"
    exit 1
fi

# ---- 4. 远程执行（expect 处理密码交互）----
# bootstrap 只取一个安装器；安装器内部自带 电脑 HTTP -> GitHub 双源回退。
REMOTE="curl -sL http://${MACIP}:8899/deploy_v5.sh | sh -s ${MODE}"

EXP=$(mktemp /tmp/kindle_push.XXXXXX)
trap 'rm -f "$EXP"' EXIT
cat > "$EXP" <<'EXP_SCRIPT'
set timeout 45
set pw   [lindex $argv 0]
set ip   [lindex $argv 1]
set port [lindex $argv 2]
set cmd  [lindex $argv 3]
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/kindle_known_hosts \
          -o ConnectTimeout=8 -p $port root@$ip $cmd
expect {
    -re "(?i)password:" { send "$pw\r"; exp_continue }
    -re "(?i)yes/no"    { send "yes\r"; exp_continue }
    timeout { exit 2 }
    eof
}
catch wait result
exit [lindex $result 3]
EXP_SCRIPT

echo "· 通过 SSH 触发 WiFi 安装（版式=${MODE}）..."
OK=0
for PW in "" root mario alpine kindle fiona 123456; do
    if expect "$EXP" "$PW" "$IP" "$PORT" "$REMOTE"; then
        echo "✓ 远程安装命令已执行（SSH 密码: ${PW:-空}）"
        OK=1
        break
    fi
done

if [ "$OK" -ne 1 ]; then
    echo "✗ 常见密码都试过了，SSH 认证失败。"
    echo "  把 Kindle 上 USBNetwork 显示的密码/密钥信息告诉我，我调整认证方式。"
    exit 1
fi

echo ""
echo "安装器已在 Kindle 上运行。约 10-30 秒后可回读日志验收："
echo "  ssh -p $PORT root@$IP tail -30 /mnt/us/dash/deploy_v5.log"
