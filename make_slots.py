#!/usr/bin/env python3
"""生成「待机画面固定槽位图」——供 Kindle 每天定时唤醒时下载。

背景
----
CI 每小时用 --hours 26 生成逐小时图并强推 orphan 分支 dash，
窗口外的旧小时图会被清掉（例如 18 点图在 19:xx 就 404）。
待机画面按固定时点更新，不能依赖 YYYYMMDD_HH.png 这种会过期的名字。

做法
----
从 out/index.txt（按时间从「当前整点」向后排列）里，为每个槽位小时
找到「下一次发生」的那张竖屏图，复制成稳定文件名 ss_HH.png；
另外存一份 ss_latest.png 供非更新点立即刷新使用。

槽位集合必须与设备端 /mnt/us/dash/ss_config.sh 的 SS_HOURS 一致：
当前为 6/9/12/15/18（用户 2026-11-04 定案，5 次/天，夜间不唤醒）。

产物同时保证：600x800、8 位灰度 L、PNG —— linkss 屏保的硬性要求。
"""

import os
import sys

from PIL import Image

SLOTS = [6, 9, 12, 15, 18]
WIDTH, HEIGHT = 600, 800


def normalize(src: str, dst: str) -> None:
    """统一成 linkss 要求的 600x800 / 8 位灰度 PNG。"""
    im = Image.open(src)
    if im.size != (WIDTH, HEIGHT) or im.mode != "L":
        im = im.convert("L").resize((WIDTH, HEIGHT), Image.LANCZOS)
    im.save(dst, format="PNG", optimize=True)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "out"
    index = os.path.join(out, "index.txt")
    with open(index, encoding="utf-8") as f:
        names = [
            line.strip()
            for line in f
            if line.strip().endswith(".png") and "_land" not in line
        ]
    if not names:
        raise SystemExit("index.txt 里没有竖屏图，槽位生成失败")

    # index.txt 从当前整点向后排，所以每个小时第一次出现 = 下一次发生
    picked = {}
    for name in names:
        try:
            hour = int(name[:-4].split("_")[1])
        except (IndexError, ValueError):
            continue
        if hour in SLOTS and hour not in picked:
            picked[hour] = name

    lines = [
        "# 待机画面固定槽位图（每次 CI 运行重新生成）",
        "# 槽位图 -> 源逐小时图（该槽位下一次发生的整点）",
        "# 与设备端 /mnt/us/dash/ss_config.sh 的 SS_HOURS 保持一致",
    ]
    for s in SLOTS:
        src = picked.get(s)
        if not src:
            print(f"WARN 槽位 {s:02d} 不在 26 小时窗口内", file=sys.stderr)
            continue
        dst_name = f"ss_{s:02d}.png"
        normalize(os.path.join(out, src), os.path.join(out, dst_name))
        print(f"槽位 {s:02d}: {src} -> {dst_name}")
        lines.append(f"{dst_name} -> {src}")

    normalize(os.path.join(out, names[0]), os.path.join(out, "ss_latest.png"))
    print(f"最新图: {names[0]} -> ss_latest.png")
    lines.append(f"ss_latest.png -> {names[0]}")

    with open(os.path.join(out, "slots.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    missing = [s for s in SLOTS if s not in picked]
    if missing:
        print(f"WARN 缺失槽位: {missing}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
