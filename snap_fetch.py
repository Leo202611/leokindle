#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
屏保实拍抓取器（Mac 端）：从 ntfy 附件取回 Kindle 帧缓冲原始数据，转成 PNG。

通道：
  设备(自动更新刷屏后) → 抓 /dev/fb0 原始字节 → ntfy 附件(topic=SS_SNAP_TOPIC)
  → 本脚本取回 → 按文件名里的 WxHxBPP 解码 → 存 PNG。

用法：
  python3 snap_fetch.py              # 取最新一张，存 /tmp/kindle_snap.png 并打印路径
  python3 snap_fetch.py -o out.png   # 指定输出
  python3 snap_fetch.py --rotate 90  # 若实拍是横的/倒的，旋转后存（90/180/270）

解码支持（按 bpp）：
  16 → RGB565（Kindle e-ink 常见）
   8 → 灰度
  24 → RGB
  32 → RGBA
如 ntfy 文件名未带尺寸，回退默认 600x800 / 16bpp（Kindle 8 竖屏）。
"""
import sys, os, re, argparse, urllib.request, json, tempfile, struct

TOPIC = "k8dash_snap_3f9a2c"          # 必须与设备 SS_SNAP_TOPIC 一致
NTFY = f"https://ntfy.sh/{TOPIC}"
DEFAULT_W, DEFAULT_H, DEFAULT_BPP = 600, 800, 16


def fetch_latest_attachment():
    """返回 (bytes, filename) 或 None。"""
    url = f"{NTFY}/json?poll=1"
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            data = r.read().decode("utf-8", "replace")
    except Exception as e:
        print(f"[E] 拉取 ntfy 失败: {e}", file=sys.stderr)
        return None
    latest = None
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("event") != "message":
            continue
        # ntfy 附件在消息对象的顶层 "attachment" 字段（非嵌套在 message 内）
        att = e.get("attachment")
        if att and att.get("url"):
            latest = att
    if not latest:
        print("[E] 该 topic 没有附件消息（设备还没上传过截图）", file=sys.stderr)
        return None
    att_url = latest["url"]
    fname = latest.get("name", "fb.raw")
    try:
        with urllib.request.urlopen(att_url, timeout=30) as r:
            raw = r.read()
    except Exception as e:
        print(f"[E] 下载附件失败: {e}", file=sys.stderr)
        return None
    return raw, fname


def parse_dims(fname):
    m = re.search(r"fb_(\d+)x(\d+)_(\d+)bpp", fname)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    return DEFAULT_W, DEFAULT_H, DEFAULT_BPP


def raw_to_png(raw, w, h, bpp, out_path, rotate=0):
    from PIL import Image
    n = w * h * (bpp // 8)
    buf = raw[:n]
    if bpp == 16:
        import array
        nums = array.array("H")
        nums.frombytes(buf)
        if sys.byteorder != "little":
            nums.byteswap()
        # RGB565 little-endian，逐元素展开
        nums = list(nums)
        r = [((v >> 11) & 0x1F) << 3 for v in nums]
        g = [((v >> 5) & 0x3F) << 2 for v in nums]
        b = [(v & 0x1F) << 3 for v in nums]
        img = Image.new("RGB", (w, h))
        img.putdata(list(zip(r, g, b)))
    elif bpp == 8:
        img = Image.new("L", (w, h))
        img.putdata(list(buf))
    elif bpp == 24:
        img = Image.frombytes("RGB", (w, h), buf)
    elif bpp == 32:
        img = Image.frombytes("RGBA", (w, h), buf).convert("RGB")
    else:
        raise ValueError(f"不支持的 bpp={bpp}")
    if rotate:
        img = img.rotate(rotate, expand=True)
    img.save(out_path)
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="/tmp/kindle_snap.png")
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270])
    args = ap.parse_args()

    try:
        from PIL import Image  # noqa
    except ImportError:
        print("[E] 需要 Pillow：pip install Pillow", file=sys.stderr)
        sys.exit(2)

    res = fetch_latest_attachment()
    if not res:
        sys.exit(1)
    raw, fname = res
    w, h, bpp = parse_dims(fname)
    print(f"[i] 附件 {fname}  推断尺寸 {w}x{h} bpp={bpp}  原始 {len(raw)} 字节")
    try:
        out = raw_to_png(raw, w, h, bpp, args.out, rotate=args.rotate)
    except Exception as e:
        print(f"[E] 转换失败: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"[OK] 已存: {out}  ({w}x{h}, bpp={bpp})")


if __name__ == "__main__":
    main()
