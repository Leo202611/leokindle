# -*- coding: utf-8 -*-
"""卡通生肖形象绘制（剪纸/年画风格，适配 e-ink 灰度屏）。

素材来源
--------
参考用户提供的"万年历"App 截图里"冲煞"栏的生肖剪影：
实心剪影 + 白色镂空卷云纹，动态姿态。把这套造型提取成黑白 PNG
（`zodiac_assets/<生肖>.png`，白底黑剪影，镂空处保持白），
在 e-ink 上正好是"黑纸剪 + 白镂空"的效果，比线描卡通清晰得多。

`zodiac_assets/` 里缺哪只（例如素材还没补齐），就退回 `_fallback()`
的手绘剪纸版，保证不会开天窗。

接口
----
    draw_zodiac(img, d, sheng, cx, cy, s)
        在 (cx, cy) 处放一个尺寸约 s 的生肖剪影。
        s 指外接框边长，图片按比例缩放后居中。
"""

import os

from PIL import Image, ImageDraw

BLACK, WHITE, GRAY = 0, 255, 70

ASSET_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zodiac_assets")
_CACHE = {}


def _asset(sheng):
    """取剪纸素材（白底黑剪影的 L 模式图），没有则返回 None。"""
    if sheng in _CACHE:
        return _CACHE[sheng]
    p = os.path.join(ASSET_DIR, "%s.png" % sheng)
    img = None
    if os.path.exists(p):
        try:
            img = Image.open(p).convert("L")
        except Exception:
            img = None
    _CACHE[sheng] = img
    return img


# ---------------------------------------------------------------- 基础件

def _arc(d, box, start, end, fill=BLACK, width=2):
    """画弧线，自动纠正包围盒的左右/上下顺序。

    PIL 要求 x1>=x0 且 y1>=y0，左右镜像的弧直接写会抛 ValueError。
    """
    x0, y0, x1, y1 = box
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    d.arc([x0, y0, x1, y1], start=start, end=end, fill=fill, width=width)


def _oval(d, cx, cy, rx, ry, lw=2, fill=None, outline=BLACK):
    box = [cx - rx, cy - ry, cx + rx, cy + ry]
    if fill is not None:
        d.ellipse(box, fill=fill)
    if outline is not None and lw > 0:
        d.ellipse(box, outline=outline, width=lw)


# ---------------------------------------------------------------- 兜底手绘

def _fallback(d, sheng, cx, cy, s):
    """素材缺失时的兜底：画个圆脸，不至于开天窗。

    12 只的剪纸素材现已全部提取到 ``zodiac_assets/``，正常不会走到这里；
    保留只是为了防止个别素材损坏时右栏出现空白。
    """
    lw = max(2, int(s * 0.022))
    _oval(d, cx, cy, s * 0.26, s * 0.26, lw)
    d.ellipse([cx - s * 0.12, cy - s * 0.06, cx - s * 0.06, cy], fill=BLACK)
    d.ellipse([cx + s * 0.06, cy - s * 0.06, cx + s * 0.12, cy], fill=BLACK)
    _arc(d, [cx - s * 0.10, cy + s * 0.02, cx + s * 0.10, cy + s * 0.16],
         20, 160, BLACK, max(2, int(s * 0.016)))


# ---------------------------------------------------------------- 主接口

def draw_zodiac(img, d, sheng, cx, cy, s):
    """在 (cx, cy) 处放一个剪纸风格的生肖，s 为外接框边长。

    img 为主画布（用于贴图），d 为该画布的 ImageDraw。
    """
    a = _asset(sheng)
    if a is not None:
        sc = s / float(max(a.width, a.height))
        w = max(1, int(round(a.width * sc)))
        h = max(1, int(round(a.height * sc)))
        r = a.resize((w, h), Image.LANCZOS)
        # 反相灰度当蒙版：只把黑色剪影压到画布上，镂空处透出底色
        m = r.point(lambda v: 255 - v)
        img.paste(0, (int(cx - w / 2.0), int(cy - h / 2.0)), m)
        return
    _fallback(d, sheng, cx, cy, s)
