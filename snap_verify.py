#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
屏保真机核查器（Agent 用）：取 Kindle 真机帧缓冲截图，与云端「应显示」的图比对，下判断。

流程：
  1. 取真机实拍：ntfy 最新附件(设备自动上传的 /dev/fb0 原始帧缓冲) → 转 PNG
  2. 取应显示图：GitHub API(同设备首选源) 的 ss_<HH>.png / 回退 ss_latest.png / CDN
  3. 两者灰度化后算 MAE（均绝对误差）并生成差异图
  4. 存三张图，打印量化结论；Agent 再用视觉读真机图确认语义（时间/天气/电量是否正确）

用法：
  python3 snap_verify.py            # 自动取当前北京整点槽位作应显示图
  python3 snap_verify.py --slot 12  # 指定槽位（如核对 12:00 那张）
  python3 snap_verify.py --no-expected  # 只取真机图（设备刚部署、云端还没对应图时）

判读阈值（灰度 MAE，0-255）：
  < 8   基本匹配（e-ink 抖动/量化内的正常差异）
  8-25  有差异，需人工/视觉核对
  > 25  明显不符：可能未更新、显示了错误槽位、或刷屏失败
"""
import sys, os, re, argparse, urllib.request, json, io
from PIL import Image

TOPIC = "k8dash_snap_3f9a2c"
NTFY = f"https://ntfy.sh/{TOPIC}"
GH_API = "https://api.github.com/repos/Leo202611/leokindle/contents"
CDN = "https://gcore.jsdelivr.net/gh/Leo202611/leokindle@dash"
BRANCH = "dash"

REAL = "/tmp/kindle_real.png"
EXP = "/tmp/kindle_expected.png"
DIFF = "/tmp/kindle_diff.png"


def fetch_bytes(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_real():
    """取 ntfy 最新帧缓冲附件 → 转 PNG，返回 (path, dims)。"""
    import snap_fetch  # 复用转换逻辑
    data = fetch_bytes(f"{NTFY}/json?poll=1")
    latest = None
    for line in data.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("event") != "message":
            continue
        att = e.get("attachment")
        if att and att.get("url"):
            latest = att
    if not latest:
        raise RuntimeError("ntfy 没有真机截图（设备还没上传过；先点 KUAL 5 部署，等下一个整点自动抓）")
    raw = fetch_bytes(latest["url"])
    w, h, bpp, stride = snap_fetch.parse_dims(latest.get("name", ""))
    snap_fetch.raw_to_png(raw, w, h, bpp, REAL, stride=stride)
    return REAL, (w, h, bpp)


def fetch_expected(hh):
    """取云端应显示图（ss_<hh>.png 优先，回退 ss_latest.png、CDN）。返回 path 或 None。"""
    cand = [f"ss_{hh:02d}.png", "ss_latest.png"]
    for name in cand:
        # 1) GitHub API raw（设备首选源）
        try:
            raw = fetch_bytes(f"{GH_API}/{name}?ref={BRANCH}",
                              headers={"Accept": "application/vnd.github.raw"})
            if raw[:8] == b"\x89PNG\r\n\x1a\n":
                Image.open(io.BytesIO(raw)).save(EXP)
                return EXP, name
        except Exception:
            pass
        # 2) CDN 回退
        try:
            raw = fetch_bytes(f"{CDN}/{name}")
            if raw[:8] == b"\x89PNG\r\n\x1a\n":
                Image.open(io.BytesIO(raw)).save(EXP)
                return EXP, name
        except Exception:
            pass
    return None, None


def grayscale(img):
    return img.convert("L")


def verify(real_path, exp_path):
    a = grayscale(Image.open(real_path))
    b = grayscale(Image.open(exp_path))
    if a.size != b.size:
        b = b.resize(a.size)
    da = a.load(); db = b.load()
    W, H = a.size
    total = 0; mx = 0
    diff = Image.new("L", (W, H))
    dd = diff.load()
    for y in range(H):
        for x in range(W):
            d = abs(da[x, y] - db[x, y])
            total += d
            if d > mx:
                mx = d
            dd[x, y] = min(255, d * 3)  # 放大差异便于肉眼看
    mae = total / (W * H)
    diff.save(DIFF)
    return mae, mx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot", type=int, default=None, help="指定应显示槽位(小时)，默认当前北京整点")
    ap.add_argument("--no-expected", action="store_true")
    args = ap.parse_args()

    try:
        real, dims = fetch_real()
    except Exception as e:
        print(f"[E] 取真机截图失败: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"[OK] 真机实拍: {real}  (帧缓冲 {dims[0]}x{dims[1]} bpp={dims[2]})")

    if args.no_expected:
        print("[i] 跳过应显示图比对（--no-expected）。Agent 请直接用视觉读上图判断内容。")
        return

    if args.slot is None:
        from datetime import datetime, timezone, timedelta
        bj = datetime.now(timezone(timedelta(hours=8)))
        slot = bj.hour
    else:
        slot = args.slot
    exp, name = fetch_expected(slot)
    if not exp:
        print(f"[E] 云端找不到 ss_{slot:02d}.png / ss_latest.png，无法比对。", file=sys.stderr)
        sys.exit(1)
    print(f"[OK] 应显示图: {exp}  (源 {name})")

    mae, mx = verify(real, exp)
    print(f"[i] 灰度 MAE={mae:.2f}  最大单像素差={mx}")
    print(f"[i] 差异图: {DIFF}")
    if mae < 8:
        verdict = "✅ 基本匹配（差异在 e-ink 抖动/量化正常范围内）"
    elif mae < 25:
        verdict = "⚠️ 有差异，需 Agent 视觉核对（可能内容微调或抖动偏大）"
    else:
        verdict = "❌ 明显不符：可能未更新 / 显示错误槽位 / 刷屏失败"
    print(f"[判定] {verdict}")


if __name__ == "__main__":
    main()
