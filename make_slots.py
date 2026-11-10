#!/usr/bin/env python3
"""生成「待机画面固定槽位图」——供 Kindle 每天定时唤醒时下载。

背景
----
CI 每小时用 --hours 26 生成逐小时图；render.py 在批量模式下额外为每个
(小时, 槽位分钟) 渲染一张 ss_HH_MM.png，脚注显示该槽位时刻（当前为整点，如 20:00）。
本脚本把 out/ 里的 ss_HH_MM.png 规范化成 linkss 要求的 600x800 / 8 位灰度 PNG，
并补两张兼容/兜底图：
  * ss_HH.png      = 该小时 :00 槽位图（设备端 SS_SLOT_MINUTES 与 CI 不一致时的兜底）
  * ss_latest.png  = 最近一次已发生槽位的图（安装兜底 / 非更新点立即刷新用）

槽位集合必须与 render.py 的 SS_SLOT_MINUTES、设备端 ss_config.sh 的 SS_SLOT_MINUTES 一致。
"""

import os
import sys
import datetime
import glob

from PIL import Image

WIDTH, HEIGHT = 600, 800


def normalize(src: str, dst: str) -> None:
    """统一成 linkss 要求的 600x800 / 8 位灰度 PNG。"""
    im = Image.open(src)
    if im.size != (WIDTH, HEIGHT) or im.mode != "L":
        im = im.convert("L").resize((WIDTH, HEIGHT), Image.LANCZOS)
    im.save(dst, format="PNG", optimize=True)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "out"
    files = sorted(glob.glob(os.path.join(out, "ss_??_??.png")))
    if not files:
        raise SystemExit("out/ 里没有 ss_HH_MM.png（render.py 批量模式应生成），槽位生成失败")

    slots = {}  # (h, m) -> src path
    for p in files:
        base = os.path.basename(p)[:-4]  # 形如 ss_20_40
        try:
            h, m = (int(x) for x in base[3:].split("_"))
        except (ValueError, IndexError):
            continue
        slots[(h, m)] = p

    lines = [
        "# 待机画面固定槽位图（每次 CI 运行重新生成）",
        "# 命名 ss_HH_MM.png = 该小时 HH 的 MM 分钟槽位，脚注显示该槽位时刻（如 20:00）",
        "# 与 render.py 的 SS_SLOT_MINUTES、设备端 ss_config.sh 的 SS_SLOT_MINUTES 保持一致",
    ]

    # 1) 规范化每个槽位图
    for (h, m), src in sorted(slots.items()):
        dst = os.path.join(out, "ss_%02d_%02d.png" % (h, m))
        normalize(src, dst)
        print("槽位 %02d:%02d -> %s" % (h, m, os.path.basename(dst)))
        lines.append("%s -> %s" % (os.path.basename(dst), os.path.basename(src)))

    # 2) 每小时的 :00 槽位图作为 ss_HH.png 兜底（设备端槽位分钟对不上 CI 时用）
    for h in sorted({hh for (hh, _) in slots}):
        hour_slots = sorted(m for (hh, m) in slots if hh == h)
        if not hour_slots:
            continue
        first_m = hour_slots[0]
        normalize(slots[(h, first_m)], os.path.join(out, "ss_%02d.png" % h))
        print("兜底 ss_%02d.png -> 槽位 %02d:%02d" % (h, h, first_m))
        lines.append("ss_%02d.png -> ss_%02d_%02d.png (兜底)" % (h, h, first_m))

    # 3) ss_latest.png = 最近一次已发生的槽位（按当前本地时间）
    now = datetime.datetime.now()
    best = None
    for (h, m) in slots:
        t = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if t <= now and (best is None or t > best[0]):
            best = (t, (h, m))
    if best is None:
        # 今天都还没到任何槽位：取昨天最后一个槽位（最接近当前时刻）
        for (h, m) in slots:
            t = (now - datetime.timedelta(days=1)).replace(hour=h, minute=m, second=0, microsecond=0)
            if best is None or t > best[0]:
                best = (t, (h, m))
    if best:
        h, m = best[1]
        normalize(slots[(h, m)], os.path.join(out, "ss_latest.png"))
        print("当前应显示槽位: ss_%02d_%02d.png -> ss_latest.png" % (h, m))
        lines.append("ss_latest.png -> ss_%02d_%02d.png (最近一次已发生槽位)" % (h, m))
    else:
        any_p = next(iter(slots.values()))
        normalize(any_p, os.path.join(out, "ss_latest.png"))
        print("WARN 无法判定最近槽位，回退首张槽位图 -> ss_latest.png")
        lines.append("ss_latest.png -> %s (兜底)" % os.path.basename(any_p))

    with open(os.path.join(out, "slots.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
