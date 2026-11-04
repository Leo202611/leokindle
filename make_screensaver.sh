#!/bin/sh
# Mac 端辅助：把任意图片转成 linkss 屏保格式 bg_ss00.png
#   文件名 bg_ss00.png、分辨率 600x800、8 位灰度 PNG（Kindle 8 竖屏 / 固件 5.16.x）
# 用法：
#   make_screensaver.sh <输入图> [输出路径，默认 bg_ss00.png]
# 依赖：python3 + Pillow（pip install pillow）
IN="${1:-cur_p.png}"
OUT="${2:-bg_ss00.png}"
python3 - "$IN" "$OUT" <<'PY'
import sys
from PIL import Image
inp, outp = sys.argv[1], sys.argv[2]
im = Image.open(inp).convert('L').resize((600, 800), Image.LANCZOS)
im.save(outp, 'PNG')
print("已生成", outp, im.size, im.mode)
PY
