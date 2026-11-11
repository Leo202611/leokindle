#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kindle 仪表盘 · 真实电量云端中转读取端（GitHub Actions 调用）。

【2026-11-07 恢复启用】曾在 11-04 12:37 为省电停掉（BATT_REPORT=0、
CI 步骤注释）；11-07 用户定案「搭车上报」方案后恢复：设备改为在
每小时整点取图时复用已打开的 WiFi 顺手 POST（零额外唤醒），
电量显示在底栏**中央**（不再是右下角，右下角仍显示金价）。

链路（当前生效）：
    Kindle 每次整点取图时读 lipc battLevel/isCharging（三路兜底）
      -> POST 到 ntfy.sh 公共 topic（ss_update_once.sh 的 report_batt）
      -> CI 每小时 :17 跑本脚本读回 2h 内最新一条
      -> 把 DASH_BATT / DASH_CHARGING 写进 $GITHUB_ENV
      -> render.py --batt N [--charging] 烧进整套 PNG 的底栏中央
      -> 设备下一整点取图显示（约滞后 1h，电量慢变量下误差 <1%）
    读不到任何上报时 DASH_BATT 为空 -> 中央留白；若有历史上报则始终用最近一次已知值，
    保证屏幕上不无故留白（电量慢变量，陈旧值误差极小）。

为什么是 ntfy.sh：
  * 匿名可写可读，无 token / 无账号 / 无密钥，设备脚本里不必内置会过期的凭据；
  * 消息默认缓存 12 小时，正好覆盖「设备每小时上报、CI 每小时读取」的节奏；
  * /json?poll=1 直接返回缓存消息，无需轮询长连接。
  对比：webhook.site 匿名 token 只有 ~7 天有效期（实测 expiry≈604799s），
  写进不易更新的设备脚本里会静默失效，故只作为历史备选，不做主通道。

用法：
    python3 batt_relay.py >> "$GITHUB_ENV"       # CI 中
    python3 batt_relay.py                        # 本地调试，打印两行 KEY=VALUE
诊断信息一律走 stderr，绝不污染 stdout（stdout 是 GITHUB_ENV 格式）。

可用环境变量覆盖（仅用于本地调试）：
    DASH_BATT_TOPIC     ntfy topic
    DASH_BATT_MAX_AGE   接受的最大上报年龄（秒），默认 7200
"""

import json
import os
import sys
import time
import urllib.request

TOPIC = os.environ.get("DASH_BATT_TOPIC", "k8dash_batt_7f3c9e2a")
MAX_AGE = int(os.environ.get("DASH_BATT_MAX_AGE", "7200"))
URL = "https://ntfy.sh/%s/json?poll=1&since=12h" % TOPIC


def log(msg):
    print(msg, file=sys.stderr)


def read_latest():
    """返回 (batt:str, charging:int, age:int|None)。

    优先采用 MAX_AGE 内的上报；若没有新鲜上报，则退回「最近一条已知上报」
    （即使已超出 MAX_AGE），保证屏幕上始终显示最近一次已知电量，绝不无故留白。
    ntfy 匿名 topic 默认缓存 12h，故离线超过 ~12h 才会真正无值。
    """
    batt, charging, used_time = "", 0, None
    # 最近一条有效上报（任何年龄），作为回退
    last_batt, last_charging, last_time = "", 0, None
    try:
        req = urllib.request.Request(URL, headers={"User-Agent": "leokindle-dash-ci/1"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except Exception as exc:
        log("电量中转读取失败: %s -> 回落「电量：--」" % exc)
        return batt, charging, None

    now = int(time.time())
    # ntfy 的 /json 是 NDJSON，按时间正序返回；逐条覆盖，最后一条有效即为最新。
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("event") != "message":
            continue
        try:
            t = int(ev.get("time") or 0)
        except (TypeError, ValueError):
            t = 0
        # 时钟未来偏差超过 5 分钟丢弃，避免设备校时失败时污染。
        if t and now - t < -300:
            continue
        try:
            payload = json.loads(ev.get("message") or "")
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        b = payload.get("batt")
        # 只接受整数，拒绝 "73" 之类字符串和 bool（bool 是 int 的子类）
        if isinstance(b, bool) or not isinstance(b, int) or not (0 <= b <= 100):
            continue
        c = payload.get("charging", 0)
        is_c = 1 if str(c) in ("1", "true", "True") else 0
        # 记录最近一条（任何年龄）作为回退
        last_batt, last_charging, last_time = str(b), is_c, t
        # 新鲜的（MAX_AGE 内）作为首选
        if t and now - t <= MAX_AGE:
            batt, charging, used_time = last_batt, is_c, (now - t)

    # 没有新鲜上报 -> 退回最近一次已知值（保证屏幕上始终有电量，绝不无故留白）
    if not batt and last_batt:
        batt, charging, used_time = last_batt, last_charging, (now - last_time if last_time else None)

    return batt, charging, ((now - used_time) if used_time else None)


def main():
    batt, charging, age = read_latest()
    if batt:
        log("电量中转命中: batt=%s charging=%s age=%ss topic=%s"
            % (batt, charging, age, TOPIC))
    else:
        log("电量中转: %s 上无 %s 秒内的新鲜上报，退回最近一次已知值 batt=%s"
            % (TOPIC, MAX_AGE, batt))
    # 这两行是唯一写进 stdout 的内容，供 >> "$GITHUB_ENV" 使用。
    print("DASH_BATT=" + batt)
    print("DASH_CHARGING=" + str(charging))


if __name__ == "__main__":
    main()
