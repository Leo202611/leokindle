# -*- coding: utf-8 -*-
"""卡通生肖形象绘制（e-ink 灰度简笔风格）。

单独成模块，render.py 用 import 引入。
好处：生肖图形有近 500 行，独立文件便于单独预览和迭代，
也不会像之前那样在主文件里插错位置、产生重复代码块。

风格约定：
  - 纯黑白两色 + 少量灰，适配 Kindle 8 的 8bpp 灰度屏
  - 每个生肖一个分支，靠特征部件区分（马=长吻+鬃毛，牛=勾形角，兔=长耳…）
  - 所有形状以 (cx, cy) 为中心、s 为尺寸单位定义，便于任意缩放
"""

from PIL import ImageDraw

BLACK, WHITE, GRAY = 0, 255, 70


def _eye(d, cx, cy, r, col=BLACK):
    """眼睛：黑点 + 白色高光。"""
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    hr = r * 0.38
    d.ellipse([cx + r * 0.28 - hr, cy - r * 0.34 - hr,
               cx + r * 0.28 + hr, cy - r * 0.34 + hr], fill=WHITE)


def _arc(d, box, start, end, fill=BLACK, width=2):
    """画弧线，自动纠正包围盒的左右/上下顺序。

    生肖图形大量使用左右镜像的弧：偏移量为负时直接写 [x0,y0,x1,y1]
    会让 x0 > x1，PIL 抛 ValueError。这里统一规范化。
    """
    x0, y0, x1, y1 = box
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    d.arc([x0, y0, x1, y1], start=start, end=end, fill=fill, width=width)


def _zigzag(d, x0, y0, x1, y1, n, amp, col=BLACK, width=2):
    """折线（虎纹、马鬃）。"""
    pts = []
    for i in range(n + 1):
        t = i / float(n)
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t
        if i % 2 == 1:
            y += amp if x1 >= x0 else -amp
        pts.append((x, y))
    d.line(pts, fill=col, width=width, joint="curve")


def _smile(d, cx, cy, w, h, col=BLACK, width=2):
    """向下弯的嘴角。"""
    _arc(d, [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
         20, 160, col, width)


def _body(d, cx, cy, s, lw=None):
    """通用躯干（一个椭圆），各生肖共用。"""
    lw = lw or max(2, int(s * 0.024))
    d.ellipse([cx - s * 0.28, cy - s * 0.02, cx + s * 0.28, cy + s * 0.37],
              outline=BLACK, width=lw)


def draw_zodiac(d, sheng, cx, cy, s):
    """在 (cx, cy) 处画一个尺寸约 s 的卡通生肖。sheng 取十二生肖之一。"""
    lw = max(2, int(s * 0.024))

    # ---------------- 马：侧脸，长吻朝右 + 鬃毛 ----------------
    # 朝右是刻意的：形象画在右栏靠右，吻部朝右会顶到边界，
    # 朝左才留得住（头在右、吻伸向左，与"马回头"的常见画法一致）。
    if sheng == "马":
        hx, hy = cx - s * 0.02, cy - s * 0.15
        _body(d, cx, cy, s, lw)
        # 脖子：两条略斜的粗线（不用单条粗斜杠，那会糊成一个黑方块）
        for dx in (-s * 0.045, s * 0.045):
            d.line([(cx + dx, cy + s * 0.20), (hx + dx * 0.5, hy + s * 0.10)],
                   fill=BLACK, width=max(3, int(s * 0.036)), joint="curve")
        # 鬃毛：沿颈脊一列锯齿
        _zigzag(d, hx - s * 0.10, hy - s * 0.14, hx + s * 0.16, hy - s * 0.22,
                6, s * 0.036, BLACK, max(2, int(s * 0.019)))
        # 尖耳（在后上方）
        d.polygon([(hx - s * 0.14, hy - s * 0.14),
                   (hx - s * 0.13, hy - s * 0.34),
                   (hx - s * 0.02, hy - s * 0.15)], outline=BLACK, width=lw)
        # 头骨：横向拉长的椭圆
        d.ellipse([hx - s * 0.14, hy - s * 0.16, hx + s * 0.24, hy + s * 0.15],
                  outline=BLACK, width=lw)
        # 吻部：向左下的长锥
        d.polygon([(hx - s * 0.08, hy - s * 0.10),
                   (hx - s * 0.08, hy + s * 0.12),
                   (hx - s * 0.34, hy + s * 0.04),
                   (hx - s * 0.34, hy - s * 0.02)],
                  fill=WHITE, outline=BLACK, width=lw)
        # 鼻孔
        d.ellipse([hx - s * 0.29, hy + s * 0.00, hx - s * 0.245, hy + s * 0.045],
                  fill=BLACK)
        # 眼
        _eye(d, hx + s * 0.04, hy - s * 0.065, s * 0.028)
        # 嘴
        d.line([(hx - s * 0.32, hy + s * 0.035), (hx - s * 0.14, hy + s * 0.09)],
               fill=BLACK, width=max(2, int(s * 0.015)))
        return

    # ---------------- 牛：宽脸 + 勾形角 ----------------
    if sheng == "牛":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.14
        # 角：先向外上张、再向内勾（牛角的典型形状）
        for sgn in (-1, 1):
            bx = cx + sgn * s * 0.17
            d.line([(bx, hy - s * 0.18),
                    (bx + sgn * s * 0.11, hy - s * 0.26),
                    (bx + sgn * s * 0.14, hy - s * 0.38),
                    (bx + sgn * s * 0.05, hy - s * 0.44),
                    (bx - sgn * s * 0.02, hy - s * 0.38)],
                   fill=BLACK, width=max(3, int(s * 0.030)), joint="curve")
        d.ellipse([cx - s * 0.27, hy - s * 0.26, cx + s * 0.27, hy + s * 0.24],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.17, hy - s * 0.16, cx + s * 0.17, hy + s * 0.22],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.05, s * 0.032)
        _eye(d, cx + s * 0.09, hy - s * 0.05, s * 0.032)
        # 鼻镜
        d.ellipse([cx - s * 0.13, hy + s * 0.06, cx + s * 0.13, hy + s * 0.21],
                  outline=BLACK, width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.06, hy + s * 0.11, cx - s * 0.015, hy + s * 0.17],
                  fill=BLACK)
        d.ellipse([cx + s * 0.015, hy + s * 0.11, cx + s * 0.06, hy + s * 0.17],
                  fill=BLACK)
        return

    # ---------------- 虎：圆脸 + 王字额 + 虎纹 ----------------
    if sheng == "虎":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.14
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.24 - s * 0.08, hy - s * 0.28,
                       cx + sgn * s * 0.24 + s * 0.08, hy - s * 0.12],
                      outline=BLACK, width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.28, hy - s * 0.26, cx + s * 0.28, hy + s * 0.26],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.18, hy - s * 0.16, cx + s * 0.18, hy + s * 0.22],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.10, hy - s * 0.04, s * 0.034)
        _eye(d, cx + s * 0.10, hy - s * 0.04, s * 0.034)
        # 王字
        wx, wy, u = cx, hy - s * 0.16, s * 0.055
        for p, q in (((wx - u, wy - u), (wx + u, wy - u)),
                     ((wx - u, wy), (wx + u, wy)),
                     ((wx, wy - u), (wx, wy + u))):
            d.line([p, q], fill=BLACK, width=max(2, int(s * 0.016)))
        # 颊部虎纹
        for sgn in (-1, 1):
            for k in range(3):
                d.line([(cx + sgn * s * 0.20, hy - s * 0.10 + k * s * 0.07),
                        (cx + sgn * s * 0.27, hy - s * 0.13 + k * s * 0.07)],
                       fill=BLACK, width=max(2, int(s * 0.014)))
        _smile(d, cx, hy + s * 0.10, s * 0.16, s * 0.10, BLACK,
               max(2, int(s * 0.016)))
        return

    # ---------------- 兔：长耳 + 门牙 ----------------
    if sheng == "兔":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.10
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.13 - s * 0.07, hy - s * 0.46,
                       cx + sgn * s * 0.13 + s * 0.07, hy - s * 0.14],
                      outline=BLACK, width=max(2, int(s * 0.018)))
            d.ellipse([cx + sgn * s * 0.13 - s * 0.030, hy - s * 0.40,
                       cx + sgn * s * 0.13 + s * 0.030, hy - s * 0.20], fill=BLACK)
        d.ellipse([cx - s * 0.24, hy - s * 0.24, cx + s * 0.24, hy + s * 0.24],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.15, hy - s * 0.14, cx + s * 0.15, hy + s * 0.21],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.05, s * 0.033)
        _eye(d, cx + s * 0.09, hy - s * 0.05, s * 0.033)
        d.polygon([(cx - s * 0.03, hy + s * 0.06), (cx + s * 0.03, hy + s * 0.06),
                   (cx, hy + s * 0.11)], fill=BLACK)
        _smile(d, cx, hy + s * 0.13, s * 0.10, s * 0.08, BLACK,
               max(2, int(s * 0.015)))
        d.rectangle([cx - s * 0.035, hy + s * 0.16, cx + s * 0.035, hy + s * 0.22],
                    outline=BLACK, width=max(1, int(s * 0.012)))
        return

    # ---------------- 龙：鹿角 + 长吻 + 龙须 ----------------
    if sheng == "龙":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.14
        for sgn in (-1, 1):
            d.line([(cx + sgn * s * 0.16, hy - s * 0.22),
                    (cx + sgn * s * 0.22, hy - s * 0.40)], fill=BLACK,
                   width=max(2, int(s * 0.020)))
            d.line([(cx + sgn * s * 0.22, hy - s * 0.40),
                    (cx + sgn * s * 0.32, hy - s * 0.46)], fill=BLACK,
                   width=max(2, int(s * 0.018)))
            d.line([(cx + sgn * s * 0.20, hy - s * 0.32),
                    (cx + sgn * s * 0.32, hy - s * 0.34)], fill=BLACK,
                   width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.25, hy - s * 0.24, cx + s * 0.25, hy + s * 0.22],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.16, hy - s * 0.14, cx + s * 0.16, hy + s * 0.20],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.06, s * 0.032)
        _eye(d, cx + s * 0.09, hy - s * 0.06, s * 0.032)
        d.ellipse([cx - s * 0.14, hy + s * 0.06, cx + s * 0.14, hy + s * 0.24],
                  outline=BLACK, width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.02, hy + s * 0.12, cx + s * 0.02, hy + s * 0.16],
                  fill=BLACK)
        for sgn in (-1, 1):
            _arc(d, [cx + sgn * s * 0.10, hy + s * 0.02,
                     cx + sgn * s * 0.26, hy + s * 0.30],
                 270, 90, BLACK, max(2, int(s * 0.014)))
        return

    # ---------------- 蛇：盘成一圈 + 抬头吐信 ----------------
    if sheng == "蛇":
        _arc(d, [cx - s * 0.30, cy - s * 0.04, cx + s * 0.30, cy + s * 0.42],
             200, 340, BLACK, max(4, int(s * 0.062)))
        _arc(d, [cx - s * 0.20, cy + s * 0.02, cx + s * 0.20, cy + s * 0.34],
             20, 160, BLACK, max(4, int(s * 0.062)))
        d.line([(cx - s * 0.26, cy + s * 0.10), (cx - s * 0.30, cy - s * 0.12),
                (cx - s * 0.16, cy - s * 0.26)],
               fill=BLACK, width=max(4, int(s * 0.058)), joint="curve")
        hx, hy = cx - s * 0.14, cy - s * 0.28
        d.ellipse([hx - s * 0.13, hy - s * 0.10, hx + s * 0.13, hy + s * 0.12],
                  outline=BLACK, width=max(2, int(s * 0.022)))
        _eye(d, hx + s * 0.03, hy - s * 0.01, s * 0.028)
        d.line([(hx - s * 0.12, hy + s * 0.03), (hx - s * 0.22, hy + s * 0.05)],
               fill=BLACK, width=max(2, int(s * 0.014)))
        d.line([(hx - s * 0.22, hy + s * 0.05), (hx - s * 0.30, hy + s * 0.01)],
               fill=BLACK, width=max(2, int(s * 0.012)))
        d.line([(hx - s * 0.22, hy + s * 0.05), (hx - s * 0.30, hy + s * 0.09)],
               fill=BLACK, width=max(2, int(s * 0.012)))
        return

    # ---------------- 羊：卷角 + 细长脸 ----------------
    if sheng == "羊":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.12
        for sgn in (-1, 1):
            bx = cx + sgn * s * 0.24
            _arc(d, [bx - s * 0.11, hy - s * 0.36, bx + s * 0.11, hy - s * 0.14],
                 180, 90, BLACK, max(2, int(s * 0.026)))
            _arc(d, [bx - s * 0.07, hy - s * 0.33, bx + s * 0.07, hy - s * 0.21],
                 0, 270, BLACK, max(2, int(s * 0.020)))
        d.ellipse([cx - s * 0.23, hy - s * 0.22, cx + s * 0.23, hy + s * 0.26],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.14, hy - s * 0.12, cx + s * 0.14, hy + s * 0.22],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.08, hy - s * 0.04, s * 0.030)
        _eye(d, cx + s * 0.08, hy - s * 0.04, s * 0.030)
        d.polygon([(cx - s * 0.025, hy + s * 0.08), (cx + s * 0.025, hy + s * 0.08),
                   (cx, hy + s * 0.12)], fill=BLACK)
        _smile(d, cx, hy + s * 0.14, s * 0.09, s * 0.07, BLACK,
               max(2, int(s * 0.015)))
        return

    # ---------------- 猴：桃脸 + 外翻耳 + 大嘴 ----------------
    if sheng == "猴":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.14
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.26 - s * 0.09, hy - s * 0.12,
                       cx + sgn * s * 0.26 + s * 0.09, hy + s * 0.08],
                      outline=BLACK, width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.26, hy - s * 0.26, cx + s * 0.26, hy + s * 0.24],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.18, hy - s * 0.18, cx + s * 0.18, hy + s * 0.20],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.06, s * 0.032)
        _eye(d, cx + s * 0.09, hy - s * 0.06, s * 0.032)
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.16 - s * 0.07, hy + s * 0.02,
                       cx + sgn * s * 0.16 + s * 0.07, hy + s * 0.14],
                      outline=BLACK, width=max(2, int(s * 0.014)))
        d.ellipse([cx - s * 0.05, hy + s * 0.06, cx + s * 0.05, hy + s * 0.13],
                  fill=BLACK)
        _smile(d, cx, hy + s * 0.16, s * 0.18, s * 0.12, BLACK,
               max(2, int(s * 0.016)))
        return

    # ---------------- 鸡：鸡冠 + 喙 + 爪 ----------------
    if sheng == "鸡":
        d.ellipse([cx - s * 0.26, cy - s * 0.02, cx + s * 0.26, cy + s * 0.34],
                  outline=BLACK, width=lw)
        hy = cy - s * 0.12
        for k, off in enumerate((-0.11, 0.0, 0.11)):
            top = hy - s * 0.30 - (s * 0.02 if k == 1 else 0)
            d.ellipse([cx + off * s - s * 0.055, top,
                       cx + off * s + s * 0.055, hy - s * 0.16], fill=BLACK)
        d.ellipse([cx - s * 0.19, hy - s * 0.20, cx + s * 0.19, hy + s * 0.20],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.12, hy - s * 0.12, cx + s * 0.12, hy + s * 0.18],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.07, hy - s * 0.05, s * 0.030)
        d.polygon([(cx - s * 0.04, hy + s * 0.02), (cx + s * 0.04, hy + s * 0.02),
                   (cx, hy + s * 0.13)], fill=BLACK)
        d.ellipse([cx - s * 0.045, hy + s * 0.04, cx + s * 0.045, hy + s * 0.13],
                  fill=BLACK)
        d.line([(cx - s * 0.10, cy + s * 0.34), (cx - s * 0.14, cy + s * 0.44)],
               fill=BLACK, width=max(2, int(s * 0.016)))
        d.line([(cx + s * 0.10, cy + s * 0.34), (cx + s * 0.14, cy + s * 0.44)],
               fill=BLACK, width=max(2, int(s * 0.016)))
        return

    # ---------------- 狗：垂耳 + 黑鼻 ----------------
    if sheng == "狗":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.14
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.24 - s * 0.085, hy - s * 0.18,
                       cx + sgn * s * 0.24 + s * 0.085, hy + s * 0.18],
                      outline=BLACK, width=max(2, int(s * 0.020)))
        d.ellipse([cx - s * 0.25, hy - s * 0.24, cx + s * 0.25, hy + s * 0.24],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.16, hy - s * 0.14, cx + s * 0.16, hy + s * 0.22],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.05, s * 0.032)
        _eye(d, cx + s * 0.09, hy - s * 0.05, s * 0.032)
        d.ellipse([cx - s * 0.07, hy + s * 0.07, cx + s * 0.07, hy + s * 0.18],
                  fill=BLACK)
        d.line([(cx, hy + s * 0.18), (cx, hy + s * 0.22)],
               fill=BLACK, width=max(2, int(s * 0.014)))
        _smile(d, cx, hy + s * 0.25, s * 0.12, s * 0.08, BLACK,
               max(2, int(s * 0.014)))
        return

    # ---------------- 猪：大耳 + 圆盘鼻 ----------------
    if sheng == "猪":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.12
        for sgn in (-1, 1):
            d.polygon([(cx + sgn * s * 0.16, hy - s * 0.18),
                       (cx + sgn * s * 0.34, hy - s * 0.28),
                       (cx + sgn * s * 0.32, hy - s * 0.06)],
                      outline=BLACK, width=max(2, int(s * 0.020)))
        d.ellipse([cx - s * 0.24, hy - s * 0.24, cx + s * 0.24, hy + s * 0.24],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.15, hy - s * 0.14, cx + s * 0.15, hy + s * 0.22],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.09, hy - s * 0.05, s * 0.028)
        _eye(d, cx + s * 0.09, hy - s * 0.05, s * 0.028)
        d.ellipse([cx - s * 0.12, hy + s * 0.06, cx + s * 0.12, hy + s * 0.22],
                  outline=BLACK, width=max(2, int(s * 0.018)))
        d.ellipse([cx - s * 0.055, hy + s * 0.10, cx - s * 0.015, hy + s * 0.17],
                  fill=BLACK)
        d.ellipse([cx + s * 0.015, hy + s * 0.10, cx + s * 0.055, hy + s * 0.17],
                  fill=BLACK)
        return

    # ---------------- 鼠：大圆耳 + 小尖吻 + 卷尾 ----------------
    if sheng == "鼠":
        _body(d, cx, cy, s, lw)
        hy = cy - s * 0.10
        for sgn in (-1, 1):
            d.ellipse([cx + sgn * s * 0.24 - s * 0.11, hy - s * 0.32,
                       cx + sgn * s * 0.24 + s * 0.11, hy - s * 0.10],
                      outline=BLACK, width=max(2, int(s * 0.020)))
        d.ellipse([cx - s * 0.23, hy - s * 0.24, cx + s * 0.23, hy + s * 0.22],
                  outline=BLACK, width=lw)
        d.ellipse([cx - s * 0.15, hy - s * 0.14, cx + s * 0.15, hy + s * 0.20],
                  fill=WHITE, outline=BLACK, width=max(2, int(s * 0.018)))
        _eye(d, cx - s * 0.08, hy - s * 0.04, s * 0.032)
        _eye(d, cx + s * 0.08, hy - s * 0.04, s * 0.032)
        d.polygon([(cx - s * 0.055, hy + s * 0.09),
                   (cx + s * 0.055, hy + s * 0.09),
                   (cx, hy + s * 0.20)], fill=WHITE, outline=BLACK,
                  width=max(2, int(s * 0.015)))
        d.ellipse([cx - s * 0.022, hy + s * 0.12, cx + s * 0.022, hy + s * 0.165],
                  fill=BLACK)
        for sgn in (-1, 1):
            for k in range(3):
                d.line([(cx + sgn * s * 0.04, hy + s * 0.13 + k * s * 0.022),
                        (cx + sgn * s * 0.24, hy + s * 0.08 + k * s * 0.05)],
                       fill=BLACK, width=max(1, int(s * 0.010)))
        _arc(d, [cx + s * 0.18, cy + s * 0.10, cx + s * 0.44, cy + s * 0.40],
             170, 60, BLACK, max(2, int(s * 0.016)))
        return

    # 兜底：画个圆脸，不至于空白
    d.ellipse([cx - s * 0.26, cy - s * 0.26, cx + s * 0.26, cy + s * 0.26],
              outline=BLACK, width=lw)
    _eye(d, cx - s * 0.09, cy - s * 0.04, s * 0.032)
    _eye(d, cx + s * 0.09, cy - s * 0.04, s * 0.032)
    _smile(d, cx, cy + s * 0.12, s * 0.16, s * 0.10, BLACK,
           max(2, int(s * 0.016)))
