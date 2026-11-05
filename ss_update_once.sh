#!/bin/sh
# 单次更新待机画面（KUAL「立即更新待机画面」+ 调度器共用）
#
# 做四件事：按需开 WiFi -> 拉对应槽位 PNG -> eips 刷一次屏 -> 写入 linkss 屏保目录。
# 省电约束（用户要求「不接电源撑一周」）：
#   * 全程硬超时 SS_UPDATE_TIMEOUT 秒，超时即放弃，绝不重试；
#   * 连不上 WiFi 直接跳过下载，不空等、不 ping 循环；
#   * 用完立刻恢复 WiFi 原状态；不轮询、不整屏反复重绘、不启动 keep_awake；
#   * 只刷一次 eips（e-ink 双稳态，之后保持零耗电）。
#
# 图源命名：ss_06.png / ss_09.png / ss_12.png / ss_15.png / ss_18.png
# 是 CI 固定槽位图，不会像逐小时图那样被 orphan 分支滚动清理掉；
# 非更新点用 ss_latest.png。
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:$PATH

CONF=/mnt/us/dash/ss_config.sh
[ -f "$CONF" ] && . "$CONF"
[ -n "${SS_HOURS:-}" ]       || SS_HOURS="6 9 12 15 18"
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

log() {
    echo "[$(date +'%m-%d %H:%M:%S')] $*" >> "$SS_LOG" 2>/dev/null
    echo "$*"
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

log "===== 单次更新待机画面 ====="

# ---- 1. 计算槽位文件名 ----
# 更新点上取该槽位图 ss_HH.png（内容为当次整点的画面）。
# 非更新点（安装兜底 / 启动补刷）取 ss_latest.png —— 它的语义是
# 「最近一次已发生的更新槽位」画面，不是当前小时的实时图：
# 20:58 补刷应显示 18:00 那张，而不是 20:00，否则 5 个时辰的设定就失去意义。
HM=$(date +%H); HH=$(( ${HM#0} ))
FN=""
case " $SS_HOURS " in *" $HH "*) FN=$(printf 'ss_%02d.png' "$HH") ;; esac
[ -n "$FN" ] || FN="ss_latest.png"
log "本地 $HH 时，目标图: ${FN}（更新点: ${SS_HOURS}）"

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
    # 先画到帧缓冲：设备已经处于休眠/屏保时，linkss 只在「进入屏保」那一刻读文件，
    # 光换文件不刷屏，用户看到的仍是旧图（这正是之前 12:00 图一直挂着的原因之一）。
    PSTAT=$(lipc-get-prop com.lab126.powerd status 2>/dev/null)
    case "$PSTAT" in
        *Active*) log "GUI 活跃，跳过 eips（按电源键休眠即显示新图）" ;;
        *)
            if [ "$SKIP_EIPS" = "1" ]; then
                log "内容未变，跳过 eips 整屏刷新（仅更新文件）"
            else
                eips -f -g "$TMP" >> "$SS_LOG" 2>&1
                log "已刷屏 eips -f -g（仅一次整屏刷新）"
            fi
            ;;
    esac

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
