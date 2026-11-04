#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kindle 仪表盘 · 真实电量云端中转读取端（GitHub Actions 调用）。

链路（用户选定的 A 方案）：
    Kindle 每小时读 lipc battLevel/isCharging
      -> POST 到 ntfy.sh 公共 topic
      -> CI 每小时跑本脚本读回最新一条
      -> 把 DASH_BATT / DASH_CHARGING 写进 $GITHUB_ENV
      -> render.py --batt N [--charging] 把真实电量烧进 PNG
      -> 设备下一轮取图显示

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
    """返回 (batt:str, charging:int, age:int|None)。没有有效上报时 batt 为空串。"""
    batt, charging, used_time = "", 0, None
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
        # 超过 MAX_AGE 视为设备已离线，宁可显示「电量：--」也不显示陈旧数字。
        # 时钟未来偏差超过 5 分钟同样丢弃，避免设备校时失败时污染。
        if t and (now - t > MAX_AGE or now - t < -300):
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
        charging = 1 if str(c) in ("1", "true", "True") else 0
        batt = str(b)
        used_time = t

    return batt, charging, ((now - used_time) if used_time else None)


def main():
    batt, charging, age = read_latest()
    if batt:
        log("电量中转命中: batt=%s charging=%s age=%ss topic=%s"
            % (batt, charging, age, TOPIC))
    else:
        log("电量中转: %s 上无 %s 秒内的有效上报 -> 显示「电量：--」"
            % (TOPIC, MAX_AGE))
    # 这两行是唯一写进 stdout 的内容，供 >> "$GITHUB_ENV" 使用。
    print("DASH_BATT=" + batt)
    print("DASH_CHARGING=" + str(charging))


if __name__ == "__main__":
    main()
