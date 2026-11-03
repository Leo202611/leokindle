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


def _line(d, pts, lw=2, col=BLACK):
    d.line(pts, fill=col, width=lw, joint="curve")


def _poly(d, pts, lw=2, fill=None, outline=BLACK):
    """多边形：先填后描，描边用曲线接头（避免多边形尖角豁口）。"""
    if fill is not None:
        d.polygon(pts, fill=fill)
    if outline is not None and lw > 0:
        _line(d, list(pts) + [pts[0]], lw, outline)


def _oval(d, cx, cy, rx, ry, lw=2, fill=None, outline=BLACK):
    box = [cx - rx, cy - ry, cx + rx, cy + ry]
    if fill is not None:
        d.ellipse(box, fill=fill)
    if outline is not None and lw > 0:
        d.ellipse(box, outline=outline, width=lw)


def _spiral(d, cx, cy, r0, r1, turns, ang0, lw=2, col=BLACK):
    """阿基米德螺线，用作羊角/卷云纹。"""
    import math
    n = 48
    pts = []
    for i in range(n + 1):
        t = i / float(n)
        a = ang0 + t * turns * 2 * math.pi
        r = r0 + (r1 - r0) * t
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    _line(d, pts, lw, col)


# ---------------------------------------------------------------- 兜底手绘

def _fallback(d, sheng, cx, cy, s):
    """素材缺失时的手绘剪纸版（实心剪影 + 白色镂空）。"""
    lw = max(2, int(s * 0.022))

    if sheng == "蛇":
        # 盘成一圈 + 抬头吐信：粗线盘成螺旋，头部一个小楔形
        _spiral(d, cx - s * 0.02, cy + s * 0.08, s * 0.30, s * 0.07,
                1.35, 200, max(4, int(s * 0.085)))
        hx, hy = cx - s * 0.06, cy - s * 0.26
        d.polygon([(hx - s * 0.16, hy + s * 0.10), (hx + s * 0.14, hy + s * 0.04),
                   (hx + s * 0.11, hy - s * 0.10), (hx - s * 0.13, hy - s * 0.04)],
                  fill=BLACK)
        d.ellipse([hx + s * 0.01, hy - s * 0.05, hx + s * 0.07, hy + s * 0.01],
                  fill=WHITE)
        _line(d, [(hx - s * 0.14, hy + s * 0.02), (hx - s * 0.30, hy - s * 0.01)],
              max(1, int(s * 0.013)))
        _line(d, [(hx - s * 0.30, hy - s * 0.01), (hx - s * 0.40, hy - s * 0.07)],
              max(1, int(s * 0.012)))
        _line(d, [(hx - s * 0.30, hy - s * 0.01), (hx - s * 0.40, hy + s * 0.05)],
              max(1, int(s * 0.012)))
        return

    if sheng == "猪":
        # 胖身子 + 大塌耳 + 圆盘鼻
        _oval(d, cx - s * 0.02, cy + s * 0.10, s * 0.30, s * 0.22, lw, fill=BLACK)
        # 耳朵先画，尖要伸出头外才看得见
        for sgn in (-1, 1):
            _poly(d, [(cx + s * 0.14, cy - s * 0.12),
                      (cx + s * 0.30, cy - s * 0.34),
                      (cx + s * 0.34, cy - s * 0.04)], lw, fill=BLACK)
        _oval(d, cx + s * 0.26, cy - s * 0.06, s * 0.19, s * 0.17, lw, fill=BLACK)
        for dx in (-0.18, -0.02, 0.14):
            _poly(d, [(cx + s * dx, cy + s * 0.24), (cx + s * (dx + 0.08), cy + s * 0.24),
                      (cx + s * (dx + 0.08), cy + s * 0.40), (cx + s * dx, cy + s * 0.40)],
                  lw, fill=BLACK)
        # 卷尾
        _spiral(d, cx - s * 0.30, cy - s * 0.02, s * 0.09, s * 0.02, 0.9, 30,
                max(2, int(s * 0.022)), BLACK)
        # 鼻盘与鼻孔（白色镂空）
        _oval(d, cx + s * 0.32, cy - s * 0.02, s * 0.09, s * 0.07, 0,
              fill=BLACK, outline=None)
        d.ellipse([cx + s * 0.275, cy - s * 0.04, cx + s * 0.305, cy - s * 0.005],
                  fill=WHITE)
        d.ellipse([cx + s * 0.335, cy - s * 0.04, cx + s * 0.365, cy - s * 0.005],
                  fill=WHITE)
        # 眼与身上的卷云镂空
        d.ellipse([cx + s * 0.22, cy - s * 0.13, cx + s * 0.26, cy - s * 0.09],
                  fill=WHITE)
        _spiral(d, cx - s * 0.10, cy + s * 0.08, s * 0.13, s * 0.03, 1.1, 40,
                max(2, int(s * 0.026)), WHITE)
        return

    # 其余没素材的：画个圆脸，不至于空白
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
