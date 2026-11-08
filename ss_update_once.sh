#!/bin/sh
# 单次更新待机画面（KUAL「立即更新待机画面」+ 调度器共用）
#
# 做五件事：按需开 WiFi -> 拉对应槽位 PNG -> eips 刷一次屏 -> 写入 linkss 屏保目录
#           -> 顺手搭车上报实测电量（2026-11-07 新增，见下方 report_batt）。
# 省电约束（用户要求「不接电源撑一周」）：
#   * 全程硬超时 SS_UPDATE_TIMEOUT 秒，超时即放弃，绝不重试；
#   * 连不上 WiFi 直接跳过下载，不空等、不 ping 循环；
#   * 用完立刻恢复 WiFi 原状态；不轮询、不整屏反复重绘、不启动 keep_awake；
#   * 只刷一次 eips（e-ink 双稳态，之后保持零耗电）；
#   * 电量上报复用本次已打开的 WiFi，零额外唤醒、单次请求不重试、失败不阻断显示。
#
# 图源命名：ss_HH_MM.png 是 CI 按「小时_槽位分钟」预渲染的固定槽位图（脚注显示真实分钟，
# 如 ss_20_40.png 的「更新时间」为 20:40），不会像逐小时图那样被 orphan 分支滚动清理掉；
# 同小时整点兜底图 ss_HH.png（脚注 :00）；非更新点用 ss_latest.png。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ]       || SS_HOURS="6 9 12 15 18"
[ -n "${SS_SLOT_MINUTES:-}" ] || SS_SLOT_MINUTES="0 20 40"
[ -n "${SS_LOCAL_SRV:-}" ]   || SS_LOCAL_SRV=""
[ -n "${SS_GH_API:-}" ]      || SS_GH_API="https://api.github.com/repos/Leo202611/leokindle/contents"
[ -n "${SS_GH_BRANCH:-}" ]   || SS_GH_BRANCH="dash"
[ -n "${SS_CDN:-}" ]         || SS_CDN="https://gcore.jsdelivr.net/gh/Leo202611/leokindle@dash"
[ -n "${SS_RAW:-}" ]         || SS_RAW="https://raw.githubusercontent.com/Leo202611/leokindle/dash"
SS_INSECURE="${SS_INSECURE:-1}"
CK=""
[ "$SS_INSECURE" = "1" ] && CK="-k"
[ -n "${SS_LINK_DIR:-}" ]    || SS_LINK_DIR="/mnt/us/linkss/screensavers"
[ -n "${SS_BK_DIR:-}" ]      || SS_BK_DIR="/mnt/us/linkss/backup_custom"
[ -n "${SS_DST_DIR:-}" ]     || SS_DST_DIR="/mnt/us/dash"
[ -n "${SS_FILE:-}" ]        || SS_FILE="bg_ss00.png"
[ -n "${SS_LOG:-}" ]         || SS_LOG="/mnt/us/dash/ss.log"
[ -n "${SS_LAST:-}" ]        || SS_LAST="/mnt/us/dash/ss_last"
[ -n "${SS_DONE:-}" ]        || SS_DONE="/mnt/us/dash/ss_done"
[ -n "${SS_CURL_T:-}" ]      || SS_CURL_T=20
[ -n "${SS_WIFI_WAIT:-}" ]   || SS_WIFI_WAIT=20
[ -n "${SS_UPDATE_TIMEOUT:-}" ] || SS_UPDATE_TIMEOUT=60
# 电量「搭车上报」开关与中转站（2026-11-07 恢复；设 SS_BATT_REPORT=0 可随时关掉）
[ -n "${SS_BATT_REPORT:-}" ] || SS_BATT_REPORT=1
[ -n "${SS_BATT_TOPIC:-}" ]  || SS_BATT_TOPIC="k8dash_batt_7f3c9e2a"
SS_BATT_URL="https://ntfy.sh/$SS_BATT_TOPIC"

# 屏保实拍截图中继站（2026-11-08 新增）：自动更新刷屏后由调度器抓 /dev/fb0 原始帧缓冲
# 上传到独立 ntfy topic 附件，Mac 端 snap_fetch.py 转换后即可免拍照查看屏保实拍。
# 设 SS_SNAP_ENABLE=0 可整体关闭；topic 名随机化避免被猜到。
[ -n "${SS_SNAP_ENABLE:-}" ] || SS_SNAP_ENABLE=1
[ -n "${SS_SNAP_TOPIC:-}" ]  || SS_SNAP_TOPIC="k8dash_snap_3f9a2c"
SS_SNAP_URL="https://ntfy.sh/$SS_SNAP_TOPIC"

# 抓取当前帧缓冲原始数据并上传 ntfy 附件（仅调度器自动更新时 SS_SNAP=1 才调用）。
# 此刻设备刚 eips 刷完屏、尚未重新挂起，/dev/fb0 正是屏保画面。
# 用 sysfs 读真实 bpp/分辨率（不硬编码），文件名编码 WxHxBPP 供 Mac 端解析。
# 手动「立即更新」(KUAL 2) 不设 SS_SNAP，不会抓 fb0（那会儿屏幕是 KUAL 菜单而非屏保）。
snap_fb() {
    [ "$SS_SNAP_ENABLE" = "1" ] || return 0
    [ "${SS_SNAP:-0}" = "1" ] || return 0
    FB=/tmp/fb.raw
    BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)
    VSZ=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)
    STRIDE=$(cat /sys/class/graphics/fb0/stride 2>/dev/null)
    [ -n "$BPP" ] && [ -n "$VSZ" ] || { log "截图跳过：读不到 fb0 sysfs"; return 0; }
    W=${VSZ%,*}; H=${VSZ#*,}
    [ -n "$STRIDE" ] || STRIDE=$(( W * BPP / 8 ))
    N=$(( W * H * BPP / 8 ))
    [ "$N" -gt 0 ] 2>/dev/null || { log "截图跳过：尺寸非法 ${W}/${H}/${BPP}"; return 0; }
    cat /dev/fb0 > "$FB" 2>/dev/null
    [ -s "$FB" ] || { log "截图跳过：fb0 读取为空"; return 0; }
    HH=$(date +'%m-%d %H:%M')
    FN="fb_${W}x${H}_${BPP}bpp_s${STRIDE}.raw"
    if curl -sL $CK -T "$FB" -H "Title: 屏保实拍 $HH" -H "Filename: $FN" \
         -H "Content-Type: application/octet-stream" "$SS_SNAP_URL" 2>/dev/null; then
        log "屏保实拍已上传 ntfy($SS_SNAP_TOPIC): $FN"
    else
        log "屏保实拍上传失败（不影响显示）"
    fi
    rm -f "$FB"
}

log() {
    echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$SS_LOG" 2>/dev/null
    echo "$*"
}

# 【临时遥测 2026-11-08】上报 do_update 关键节点到 ntfy，配合调度器遥测定位 22:20 失败根因。
DBG_TOPIC="k8dash_dbg_9c1e"
dbg() {
    MSG="$(date +'%m-%d %H:%M:%S') [upd] $*"
    curl -sL -k -m 5 -X POST -H "Title: upd-debug" --data-binary "$MSG" "https://ntfy.sh/$DBG_TOPIC" >/dev/null 2>&1
}

# 日志限长：避免每天 5 次无限追加写 FAT（首次运行文件还不存在，先判存在）
SZ=0
[ -f "$SS_LOG" ] && SZ=$(wc -c < "$SS_LOG" 2>/dev/null)
if [ "${SZ:-0}" -gt 65536 ]; then
    tail -150 "$SS_LOG" > "$SS_LOG.t" 2>/dev/null && mv "$SS_LOG.t" "$SS_LOG"
fi

# 严格校验：PNG 魔数 + 600x800 + 8位灰度
# IHDR: width(16-19) height(20-23) bitdepth(24) colortype(25)
# 600=0x00000258 800=0x00000320 灰度8位=0x08 0x00
png_ok() {
    [ -s "$1" ] || return 1
    # 不用 grep 匹配带空格的 od 输出：各版本 od 分隔符可能是一格或两格空格，
    # 直接去掉全部空格后比十六进制串才可靠（否则会把合法 PNG 全部误杀）。
    MAGIC=$(head -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$MAGIC" = "89504e470d0a1a0a" ] || return 1
    DIM=$(dd if="$1" bs=1 skip=16 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$DIM" = "0000025800000320" ] || return 1
    TYP=$(dd if="$1" bs=1 skip=24 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$TYP" = "0800" ]
}

TMP=/tmp/ss_new.png
IDX=/tmp/ss_index.txt
CB="$(date +%s)$$"
DEADLINE=$(( $(date +%s) + SS_UPDATE_TIMEOUT ))
rm -f "$TMP" "$IDX"

fetch_one() {
    F_URL="$1"; F_TMO="$2"; F_GH="$3"
    [ "$(date +%s)" -lt "$DEADLINE" ] || return 1
    rm -f "$TMP"
    if [ "$F_GH" = "gh" ]; then
        curl -sL $CK -m "$F_TMO" -H "Accept: application/vnd.github.raw" \
             -o "$TMP" "$F_URL" 2>/dev/null
    else
        curl -sL $CK -m "$F_TMO" -o "$TMP" "$F_URL" 2>/dev/null
    fi
    png_ok "$TMP"
}

# 搭车上报实测电量（2026-11-07 用户定案「搭车上报」方案）。
# 本次取图时 WiFi 已经打开，顺手 POST 一条 JSON 到 ntfy 公共 topic；
# CI 每小时 :17 用 batt_relay.py 读回，把电量烧进下一轮 PNG 的底栏中央。
# 因此数值约滞后 1 小时；电量是慢变量(约0.3%/小时)，整数显示下误差 <1%。
# 省电要点：零额外唤醒、单次短超时请求、失败不重试不重试取图、绝不阻断刷屏。
# 读取三条路径（前两条为本项目 Probe5 实测，第三条来自 HA 屏保方案的启发）：
#   1) lipc-get-prop com.lab126.powerd battLevel
#   2) /sys/class/power_supply/bd7181x_bat/capacity
#   3) /usr/bin/powerd_test -s 的 "Battery Level:" 行
report_batt() {
    [ "$SS_BATT_REPORT" = "1" ] || return 0
    B=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    case "$B" in ''|*[!0-9]*) B=$(cat /sys/class/power_supply/bd7181x_bat/capacity 2>/dev/null) ;; esac
    case "$B" in ''|*[!0-9]*)
        B=$(/usr/bin/powerd_test -s 2>/dev/null \
            | awk -F: '/Battery Level/ {gsub(/[^0-9]/,"",$2); print $2; exit}') ;;
    esac
    case "$B" in ''|*[!0-9]*) log "电量上报: 三路都读不到，跳过"; return 0 ;; esac
    if [ "$B" -lt 0 ] 2>/dev/null || [ "$B" -gt 100 ] 2>/dev/null; then
        log "电量上报: 数值越界 [$B]，跳过"; return 0
    fi
    C=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
    case "$C" in 1) ;; *) C=0 ;; esac
    PAYLOAD="{\"batt\":$B,\"charging\":$C}"
    if curl -sL $CK -m 6 -o /dev/null -X POST \
            -H "Content-Type: application/json" \
            --data-binary "$PAYLOAD" "$SS_BATT_URL" 2>/dev/null; then
        log "电量上报成功: $PAYLOAD"
    else
        log "电量上报失败（不影响显示，等下一个整点）: $PAYLOAD"
    fi
    return 0
}

log "===== 单次更新待机画面 ====="
dbg "START"

# ---- 1. 计算槽位文件名 ----
# 更新点上取该槽位图 ss_HH.png（内容为当次整点的画面）。
# 非更新点（安装兜底 / 启动补刷）取 ss_latest.png —— 它的语义是
# 「最近一次已发生的更新槽位」画面，不是当前小时的实时图：
# 20:58 补刷应显示 18:00 那张，而不是 20:00，否则 5 个时辰的设定就失去意义。
HM=$(date +%H); HH=$(( ${HM#0} ))
M=$(date +%M); M=$(( ${M#0} ))
# 当前槽位分钟：SS_SLOT_MINUTES 中 ≤ 当前分钟的最大值；若当前分钟早于首个槽位
# （理论上不会发生，因 SS_SLOT_MINUTES 含 0），取首个槽位。
SM=""
for s in $SS_SLOT_MINUTES; do
    [ "$s" -le "$M" ] && SM=$s
done
[ -z "$SM" ] && SM=${SS_SLOT_MINUTES%% *}
FN=""
case " $SS_HOURS " in *" $HH "*) FN=$(printf 'ss_%02d_%02d.png' "$HH" "$SM") ;; esac
[ -n "$FN" ] || FN="ss_latest.png"
log "本地 $HH:$M 时，槽位分钟 $SM，目标图: ${FN}（更新点: ${SS_HOURS}）"
dbg "plan HH=$HH M=$M SM=$SM FN=$FN"

# 更新期间阻止设备提前重新挂起：后台 do_update 若在「重连 WiFi → 拉图 → eips」途中被
# powerd 重新挂起，会卡在 suspended 态（WiFi 还开着、进程未退出），eips 写不进帧缓冲，
# 画面便滞留旧时刻（21:20 实测曾因此卡在 21:00）。用 deferSuspend 把「下一次自动挂起」
# 延后 240s，覆盖整段更新（最坏 WiFi dance ~150s + 拉图 + eips 余量）；更新跑完后令其自然
# 失效，再交还 powerd 正常挂起（下一轮 readyToSuspend 照常设 rtcWakeup）。
# 注意：此处的 deferSuspend 只是「双保险」——真正的第一道锁在调度器 wakeupFromSuspend
# 回调里「同步」设置（后台进程启动有延迟，放在这里设太晚，会与 powerd 的重新挂起竞态）。
lipc-set-prop -i com.lab126.powerd deferSuspend 240 2>/dev/null

# ---- 2. 按需开 / 恢复 WiFi ----
# 阶段2 深睡唤醒后 WiFi 处于断连态，必须主动重连（5.16.x suspended 态无法自动重连，
# koreader-live-sleepscreen / fanzhh 均已证实）；wifi_restore() 见 ss_config.sh。
# 已连一般秒回；断连时按 SS_WIFI_RESTORE_T(默认150s) 预算重试，仍失败则跳过下载、不空等。
WIFI_WAS=1
W=$(lipc-get-prop com.lab126.cmd wirelessEnable 2>/dev/null)
[ "$W" = "0" ] && WIFI_WAS=0
if wifi_restore; then
    ST=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    log "WiFi 已就绪（enable=$W cmState=$ST）"
else
    ST=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    log "WiFi 无法恢复（cmState=$ST），本次更新将跳过下载"
fi
log "下载前 cmState=$ST"
dbg "wifi=$ST"

# ---- 3. 拉图：GitHub 槽位 -> CDN -> 电脑 HTTP -> 最新图兜底 ----
GOT=0
if [ "$ST" = "CONNECTED" ]; then
    if fetch_one "$SS_GH_API/$FN?ref=$SS_GH_BRANCH&cb=$CB" "$SS_CURL_T" gh; then
        GOT=1; log "OK GitHub 槽位图 $FN"
    fi
    if [ "$GOT" != "1" ]; then
        if fetch_one "$SS_RAW/$FN?cb=$CB" "$SS_CURL_T" plain; then
            GOT=1; log "OK raw.githubusercontent $FN"
        fi
    fi
    if [ "$GOT" != "1" ]; then
        if fetch_one "$SS_CDN/$FN?cb=$CB" "$SS_CURL_T" plain; then
            GOT=1; log "OK jsDelivr(gcore) 槽位图 $FN"
        fi
    fi
    if [ "$GOT" != "1" ] && [ -n "$SS_LOCAL_SRV" ]; then
        if fetch_one "http://$SS_LOCAL_SRV/$FN" 4 plain; then
            GOT=1; log "OK 电脑 HTTP $FN"
        fi
    fi
    # 槽位分钟图若缺失（设备 SS_SLOT_MINUTES 与 CI 不一致），先回退同小时整点图 ss_HH.png
    if [ "$GOT" != "1" ] && [ "$FN" != "ss_latest.png" ]; then
        HHFN=$(printf 'ss_%02d.png' "$HH")
        if fetch_one "$SS_CDN/$HHFN?cb=$CB" "$SS_CURL_T" plain; then
            GOT=1; log "OK 回退 $HHFN（槽位分钟图缺失）"
        fi
    fi
    # API 匿名限额 60 次/小时，万一被同网其它设备打满，走不限额的最新图通道
    if [ "$GOT" != "1" ] && [ "$FN" != "ss_latest.png" ]; then
        if fetch_one "$SS_GH_API/ss_latest.png?ref=$SS_GH_BRANCH&cb=$CB" "$SS_CURL_T" gh; then
            GOT=1; log "OK 回退 ss_latest.png (API)"
        fi
    fi
    if [ "$GOT" != "1" ] && [ "$FN" != "ss_latest.png" ]; then
        if fetch_one "$SS_CDN/ss_latest.png?cb=$CB" "$SS_CURL_T" plain; then
            GOT=1; log "OK 回退 ss_latest.png (CDN)"
        fi
    fi
    if [ "$GOT" != "1" ]; then
        # 最后兜底：读 index.txt 拿当前小时图
        curl -sL $CK -m 10 -H "Accept: application/vnd.github.raw" \
             -o "$IDX" "$SS_GH_API/index.txt?ref=$SS_GH_BRANCH&cb=$CB" 2>/dev/null
        [ -s "$IDX" ] || curl -sL $CK -m 10 -o "$IDX" \
             "$SS_CDN/index.txt?cb=$CB" 2>/dev/null
        LF=$(grep '\.png' "$IDX" 2>/dev/null | grep -v '_land' | head -1)
        if [ -n "$LF" ] && fetch_one "$SS_CDN/$LF?cb=$CB" "$SS_CURL_T" plain; then
            GOT=1; log "OK 回退 CDN index 首图 $LF"
        fi
    fi
else
    log "未联网，跳过下载（失败不重试，等下一个更新点）"
fi
rm -f "$IDX"

# ---- 4. 落盘 + 刷屏 ----
if [ "$GOT" = "1" ]; then
    # 省电：新图与上次显示内容逐字节相同则跳过 eips 整屏刷新（每小时图不同，极少触发）。
    # 仍照常更新落盘文件，保证链接/缓存一致；eips 整屏刷新才是主要耗电项。
    SKIP_EIPS=0
    if [ -f "$SS_DST_DIR/ss_current.png" ] && cmp -s "$TMP" "$SS_DST_DIR/ss_current.png"; then
        log "内容未变（与上次相同），跳过 eips 整屏刷新"
        SKIP_EIPS=1
    fi
    # 显示判决（2026-11-08 修正）：
    #   * 唤醒态的「自动整点更新」必须强制 eips 写到帧缓冲——否则设备随后重新挂起，
    #     e-ink 双稳态保留旧画面，自动更新便"看不见"（11-08 实测：11:00 已取图上报，
    #     但屏保仍显示 10:00 旧图，根因就是唤醒后 status=Active 被旧逻辑跳过 eips）。
    #   * 手动「立即更新」(KUAL 2) 不设 SS_FORCE_EIPS，保留旧行为：GUI 活跃时跳过
    #     eips，用户按电源键休眠即由 linkss 显示新图，不打扰当前操作。
    #   * 内容逐字节相同（SKIP_EIPS）则任何状态都不重绘，省电。
    PSTAT=$(lipc-get-prop com.lab126.powerd status 2>/dev/null)
    if [ "$SKIP_EIPS" = "1" ]; then
        log "内容未变，跳过 eips 整屏刷新（仅更新文件）"
    else
        case "$PSTAT" in
            *Active*)
                if [ "${SS_FORCE_EIPS:-0}" = "1" ]; then
                    eips -f -g "$TMP" >> "$SS_LOG" 2>&1
                    log "已强制刷屏 eips -f -g（唤醒态强制，保证自动更新可见）"
                else
                    log "GUI 活跃，跳过 eips（按电源键休眠即显示新图）"
                fi
                ;;
            *)
                eips -f -g "$TMP" >> "$SS_LOG" 2>&1
                log "已刷屏 eips -f -g（仅一次整屏刷新）"
                dbg "eips OK"
                ;;
        esac
    fi

    # 自动模式下抓取帧缓冲实拍（SS_SNAP=1 由调度器注入），用于免拍照验证屏保。
    # 此刻屏幕已刷成新图且 WiFi 仍连通，正是抓 fb0 的时机。
    snap_fb

    # 缓存一份到 dash 目录，供「设为屏保」与下次开机使用。
    # 用 tmp + mv：不覆写正在被 linkss 持有的 inode，也避免反复写同一簇链。
    cp "$TMP" "$SS_DST_DIR/ss_current.png.t" 2>/dev/null \
        && mv "$SS_DST_DIR/ss_current.png.t" "$SS_DST_DIR/ss_current.png" 2>/dev/null

    if [ -d "$SS_LINK_DIR" ]; then
        mkdir -p "$SS_BK_DIR" 2>/dev/null
        for f in "$SS_LINK_DIR"/*.png; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in "$SS_FILE") continue ;; esac
            mv "$f" "$SS_BK_DIR/" 2>/dev/null \
                && log "移走示例/旧图: $(basename "$f")"
        done
        cp "$TMP" "$SS_LINK_DIR/$SS_FILE.t" 2>/dev/null \
            && mv "$SS_LINK_DIR/$SS_FILE.t" "$SS_LINK_DIR/$SS_FILE" 2>/dev/null \
            && log "已写入 $SS_LINK_DIR/$SS_FILE"
    else
        log "WARN 找不到 $SS_LINK_DIR —— 请先装 linkss（;log mrpi），否则休眠不显示自定义图"
    fi
    log "更新成功，用时 $(( $(date +%s) + SS_UPDATE_TIMEOUT - DEADLINE ))s"
else
    log "更新失败，保留旧画面（省电：不重试）"
    dbg "FAIL"
fi

# ---- 4.5 电量搭车上报（WiFi 此刻仍开着，零额外唤醒）----
# 只在确实联网、且未超出本次 60s 预算时才发；失败不重试、不影响已刷好的画面。
if [ "$ST" = "CONNECTED" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; then
    report_batt
else
    log "电量上报跳过（未联网或已近超时预算）"
fi

# ---- 5. 恢复 WiFi 原状态 ----
if [ "$WIFI_WAS" = "0" ]; then
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
    log "WiFi 已关闭"
fi
rm -f "$TMP"

# ---- 6. 打点（失败也算「已尝试」，调度器据此不重复唤醒重试） ----
echo "$(date +%s)" > "$SS_LAST" 2>/dev/null
case " $SS_HOURS " in *" $HH "*) echo "$(date +%Y%m%d_%H)" > "$SS_DONE" 2>/dev/null ;; esac
sync
[ "$GOT" = "1" ] && exit 0
exit 1
