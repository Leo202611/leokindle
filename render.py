#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kindle 8 (800x600) 日历 + 天气仪表盘渲染器
数据源：Open-Meteo（免密钥）
输出：8-bit 灰度 PNG，供 Kindle 用 eips -f -g 全屏显示
"""
import json, urllib.request, urllib.parse, datetime, sys, os, math
from PIL import Image, ImageDraw, ImageFont
from lunardate import LunarDate

try:
    from zodiac import draw_zodiac
except ImportError:      # 单文件运行时兜底
    draw_zodiac = None

# GitHub Actions 等云端服务器用的是 UTC，必须显式按北京时间取"现在"
try:
    from zoneinfo import ZoneInfo
    TZLOCAL = ZoneInfo("Asia/Shanghai")
except Exception:
    TZLOCAL = datetime.timezone(datetime.timedelta(hours=8))

W, H = 600, 800   # Kindle 8 (2016) 屏幕为 600x800 竖屏，必须按此尺寸渲染，否则右侧/底部会被裁
WL, HL = 800, 600  # 横屏版式尺寸（同一块面板旋转 90° 使用）
TZ = "Asia%2FShanghai"

# ---------------------------------------------------------------------------
# eips 字符网格几何
#
# 设备端用 eips 叠加电量数字时，eips 用的是「字符格」坐标而非像素坐标，
# 所以云端必须知道每个字符格的位置和宽度，才能把预留的数字槽换算成 col/row。
#
# 这组值来自 dash_diag.sh 的实测结果（Kindle 8 / 600x800）。
# 若换机型，改这里 + 同步改 dashd.sh 的 BATT_POS 即可。
# ---------------------------------------------------------------------------
# 以下 4 个值由 dash_probe3 v3 实测标定（Kindle 8 / 2016 / 600x800），
# 与 dashd.sh 顶部常量保持一致：
#   col0 字形左缘像素 x = 40；  row0 字形顶缘像素 y = 10
#   列宽 cellW = 13.65px（20个'8'@row0 最右暗列 x=313 => (313-40)/19≈13.65）
#   行高 cellH = 38.5px（row20 '8' 顶 y≈774/776 => (776-10)/20≈38.5）
# eips 文本命令语法：eips [row] [col] "text"（row 在前，col 在后）
EIPS_X0 = 40       # eips col0 字形左缘的像素 x
EIPS_Y0 = 10       # eips row0 字形顶缘的像素 y
EIPS_CELL_W = 13.65
EIPS_CELL_H = 38.5

# 底部状态栏：竖屏与横屏共用同一套几何，
# 这样设备端叠加电量数字时 col/row 在两种模式下完全一致。
BATT_BASE_Y = 762              # 底部状态栏基线（更新 / 电量 共用）


def eips_col(x):
    """像素 x -> eips 列号"""
    return int(round((x - EIPS_X0) / float(EIPS_CELL_W)))


def eips_row(y):
    """像素 y -> eips 行号"""
    return int(round((y - EIPS_Y0) / float(EIPS_CELL_H)))

# ---------------------------------------------------------------------------
# 位置：不在代码里写死任何城市。
# 解析优先级：环境变量 > location.json（由 locate.py 在设备上自动生成）
#             > 运行时 IP 定位（兜底，精度可能只到地级市/出口节点）
# ---------------------------------------------------------------------------
DEFAULT_LOCATION = {"city": "", "region": "", "lat": None, "lon": None, "source": ""}


def _http_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "kindle-dash/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def geocode(city, region=""):
    """城市名 -> (标准中文名, 省, 纬, 经)。Open-Meteo 对中文名支持差，故拼音兜底。"""
    import unicodedata
    def to_pinyin(s):
        try:
            from pypinyin import lazy_pinyin          # 有则精确转写
            return "".join(lazy_pinyin(s))
        except Exception:
            return ""                                  # 无则试原名
    queries = []
    py = to_pinyin(city)
    if py:
        queries.append(py)
    queries.append(city)
    for q in queries:
        try:
            url = ("https://geocoding-api.open-meteo.com/v1/search?name=%s&count=20"
                   "&language=zh&format=json" % urllib.parse.quote(q))
            d = _http_json(url)
            res = d.get("results") or []
            # 优先匹配指定省
            for r in res:
                if region and r.get("admin1") and region.rstrip("省市区") in str(r.get("admin1")):
                    return str(r.get("name")), str(r.get("admin1") or ""), r["latitude"], r["longitude"]
            for r in res:
                if not region:
                    return str(r.get("name")), str(r.get("admin1") or ""), r["latitude"], r["longitude"]
        except Exception:
            continue
    return None


def ip_locate():
    """按出口 IP 定位（中文），返回 (城市, 省, 纬, 经)"""
    try:
        d = _http_json("http://ip-api.com/json/?lang=zh-CN")
        if d.get("status") == "success":
            return (str(d.get("city") or ""), str(d.get("regionName") or ""),
                    d.get("lat"), d.get("lon"))
    except Exception:
        pass
    return None


def resolve_location():
    loc = dict(DEFAULT_LOCATION)
    here = os.path.dirname(os.path.abspath(__file__))

    # 1) 环境变量 / 命令行覆盖
    if os.environ.get("DASH_LAT") and os.environ.get("DASH_LON"):
        loc.update(city=os.environ.get("DASH_CITY", ""), region=os.environ.get("DASH_REGION", ""),
                   lat=float(os.environ["DASH_LAT"]), lon=float(os.environ["DASH_LON"]),
                   source="env")
        return loc

    # 2) location.json（由 locate.py 生成并提交到仓库）
    for p in (os.path.join(here, "location.json"), "/mnt/us/dash/location.json"):
        try:
            with open(p, encoding="utf-8") as f:
                j = json.load(f)
            if j.get("lat") is not None and j.get("lon") is not None:
                loc.update(city=j.get("city", ""), region=j.get("region", ""),
                           lat=float(j["lat"]), lon=float(j["lon"]),
                           source=j.get("source", "location.json"))
                return loc
        except Exception:
            continue

    # 3) 兜底：运行时 IP 定位
    got = ip_locate()
    if got and got[2] is not None:
        loc.update(city=got[0], region=got[1], lat=float(got[2]), lon=float(got[3]),
                   source="ip-api.com(自动)")
    return loc


LOCATION = None   # 延迟到 main 里解析，避免导入时就联网

def _find_font(cands, globs):
    import glob as _g
    for p in cands:
        if p and os.path.exists(p):
            return p
    for g in globs:
        hits = sorted(_g.glob(g))
        if hits:
            return hits[0]
    return None


# 字体按优先级查找：环境变量 > macOS 系统字体 > Linux/Noto CJK > 仓库内自带
FONT_REG = _find_font(
    [os.environ.get("DASH_FONT_REG")],
    ["/System/Library/Fonts/Hiragino Sans GB.ttc",
     "/System/Library/Fonts/STHeiti Light.ttc",
     "/System/Library/Fonts/Supplemental/Songti.ttc",
     "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
     "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
     "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
     os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "*.ttf"),
     os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "*.otf"),
]) or "/System/Library/Fonts/Hiragino Sans GB.ttc"

FONT_BOLD = _find_font(
    [os.environ.get("DASH_FONT_BOLD")],
    ["/System/Library/Fonts/STHeiti Medium.ttc",
     "/System/Library/Fonts/Hiragino Sans GB.ttc",
     "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
     "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc",
     os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "*Bold*"),
]) or FONT_REG

BLACK, WHITE, GRAY, LGRAY = 0, 255, 70, 165

# ---------- WMO 天气码 → 中文 ----------
WMO = {
    0: ("晴", "sun"), 1: ("大部晴朗", "sun"), 2: ("局部多云", "partly"),
    3: ("阴", "cloud"), 45: ("雾", "fog"), 48: ("雾凇", "fog"),
    51: ("毛毛雨", "rain"), 53: ("细雨", "rain"), 55: ("小雨", "rain"),
    56: ("冻雨", "rain"), 57: ("冻雨", "rain"),
    61: ("小雨", "rain"), 63: ("中雨", "rain"), 65: ("大雨", "rain"),
    66: ("冻雨", "rain"), 67: ("冻雨", "rain"),
    71: ("小雪", "snow"), 73: ("中雪", "snow"), 75: ("大雪", "snow"), 77: ("米雪", "snow"),
    80: ("阵雨", "rain"), 81: ("阵雨", "rain"), 82: ("暴雨", "rain"),
    85: ("阵雪", "snow"), 86: ("阵雪", "snow"),
    95: ("雷阵雨", "thunder"), 96: ("雷暴冰雹", "thunder"), 99: ("雷暴冰雹", "thunder"),
}

# ---------- 二十四节气 ----------
STM = [0, 21208, 42467, 63836, 85337, 107014, 128867, 150921, 173149, 195551,
       218072, 240693, 263343, 285989, 308563, 331033, 353350, 375494, 397447,
       419210, 440795, 462224, 483532, 504758]
SOLAR = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满",
         "芒种", "夏至", "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降",
         "立冬", "小雪", "大雪", "冬至"]
# 各节气的太阳视黄经（小寒 285°，每过一个节气 +15°）
_STM_LON = [(285.0 + 15.0 * i) % 360.0 for i in range(24)]


def _julian(dt_utc):
    """UTC datetime -> 儒略日（含小数天）。"""
    y, m = dt_utc.year, dt_utc.month
    if m <= 2:
        y -= 1
        m += 12
    a = y // 100
    b = 2 - a + a // 4
    frac = (dt_utc.hour + (dt_utc.minute + dt_utc.second / 60.0) / 60.0) / 24.0
    return (int(365.25 * (y + 4716)) + int(30.6001 * (m + 1))
            + dt_utc.day + frac + b - 1524.5)


def _sun_longitude(jd):
    """太阳视黄经（度）。NOAA 低精度算法，误差 < 0.01°（≈15 分钟）。"""
    T = (jd - 2451545.0) / 36525.0
    L0 = 280.46646 + T * (36000.76983 + T * 0.0003032)
    M = math.radians(357.52911 + T * (35999.05029 - 0.0001537 * T))
    C = (math.sin(M) * (1.914602 - T * (0.004817 + 0.000014 * T))
         + math.sin(2 * M) * (0.019993 - 0.000101 * T)
         + math.sin(3 * M) * 0.000289)
    omega = math.radians(125.04 - 1934.136 * T)
    return (L0 + C - 0.00569 - 0.00478 * math.sin(omega)) % 360.0


def solar_term_date(y, n):
    """第 n 个节气（0=小寒）在 y 年的日期（北京时间）。

    直接按太阳视黄经跨过 15° 整数倍来定节气，再用牛顿迭代收敛到分钟级；
    比"1900 基准 + 平均年长"的老公式准。老公式 2026 年立冬会算成 11-08，
    实际（据万年历 App）是 11-07。
    """
    target = _STM_LON[n]
    # 初值：老公式给的近似时刻（UTC）
    base = datetime.datetime(1900, 1, 6, 2, 5)
    ms = 31556925974.7 * (y - 1900) + STM[n] * 60000
    guess = base + datetime.timedelta(milliseconds=ms)
    for _ in range(5):
        lon = _sun_longitude(_julian(guess))
        diff = (target - lon + 180.0) % 360.0 - 180.0      # 归一到 (-180, 180]
        if abs(diff) < 1e-7:
            break
        # 太阳平均每天走约 0.9856°
        guess += datetime.timedelta(days=diff / 0.9856473)
    return (guess + datetime.timedelta(hours=8)).date()      # 换算北京时


def solar_term_of(d):
    for n in range(24):
        if solar_term_date(d.year, n) == d:
            return SOLAR[n]
    return None


# ---------- 农历 ----------
LUNA_MON = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
LUNA_DAY = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]


def lunar_str(d):
    l = LunarDate.from_solar_date(d.year, d.month, d.day)
    mon = ("闰" if l.isLeapMonth else "") + LUNA_MON[l.month - 1] + "月"
    return "农历" + mon + LUNA_DAY[l.day - 1]


WEEK = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

# ---------- 干支纪年与生肖 ----------
# 生肖年以农历正月初一（春节）为界，这是民间通行的换年标准。
GAN = "甲乙丙丁戊己庚辛壬癸"
ZHI = "子丑寅卯辰巳午未申酉戌亥"
SHENG = "鼠牛虎兔龙蛇马羊猴鸡狗猪"

# 十二地支 -> 生肖（用于"日支生肖"）
ZHI_SHENG = dict(zip(ZHI, SHENG))


def jdn(y, m, d):
    """公历 -> 儒略日数。"""
    a = (14 - m) // 12
    yy = y + 4800 - a
    mm = m + 12 * a - 3
    return d + (153 * mm + 2) // 5 + 365 * yy + yy // 4 - yy // 100 + yy // 400 - 32045


def ganzhi_of_day(d):
    """公历日 -> 日干支。

    公式 index = (JDN + 49) % 60，0 = 甲子。
    已用公认锚点校验：2000-01-01 = 戊午、1949-10-01 = 甲子。
    """
    idx = (jdn(d.year, d.month, d.day) + 49) % 60
    return GAN[idx % 10] + ZHI[idx % 12]


def zodiac_of_day(d):
    """公历日 -> (生肖, 日干支)。所谓"生肖日"即日支所主的生肖。"""
    gz = ganzhi_of_day(d)
    return ZHI_SHENG[gz[1]], gz



def _lunar_new_year(y):
    """农历 y 年正月初一对应的公历 date。优先用新版 API。"""
    try:
        return LunarDate(y, 1, 1).to_solar_date()
    except AttributeError:
        return LunarDate(y, 1, 1).toSolarDate()


def ganzhi_of(d):
    """返回 (干支, 生肖, 干支年)。例：2026 年 -> ('丙午', '马', 2026)。"""
    y = d.year
    try:
        spring = _lunar_new_year(y)     # 该农历年正月初一对应的公历日
        if d < spring:
            y -= 1                                     # 春节前仍属上一干支年
    except Exception:
        pass
    idx = (y - 4) % 60
    return GAN[idx % 10] + ZHI[idx % 12], SHENG[idx % 12], y


def font(path, size):
    return ImageFont.truetype(path, size)


def big_day(d, x, y, ds, fday_path, fday_size, day_path, day_size,
            week_text, week_path, week_size, right_x, sep="日",
            sep_gap=8, week_after_sep=False, min_day_size=96, min_small=26,
            shrink_num=True, min_gap=8):
    """画大号日号 + 「日」 + 星期，三者视觉垂直居中于同一行。

    大数字高度与小字差很多，若都按同一基线画，小字会明显偏上；
    这里按各自字形 bbox 求中心线来对齐。

    **字号必须固定，不能随位数跳变。**
    早期版本用 142px 起、装不下就一路缩到 96px，结果 1~9 号是 142px、
    10 号以后变成 96px —— 同一块屏上日期大小随日期跳变，观感很差，
    而且 142px 的单个数字还会顶到上一行的"2026年11月"。
    现在日号字号由调用方固定（竖屏 104px、横屏 88px），
    横向放不下时**只缩「日」和星期这两个小字**，日号绝不动。
    这样单双数字的日号高度一致，观感统一。

    竖屏右栏净宽只有 238px，104px 字号下双位数("31")宽 114px，
    加「日」26px 与「星期日」84px 刚好排得下，实测互不重叠。

    week_after_sep=True 时星期紧跟在「日」后面（横屏用：右栏宽 382）。
    """
    ns = fday_size
    ds_size, ws = day_size, week_size
    gap = sep_gap
    while True:
        nf = font(fday_path, ns)
        sf = font(day_path, ds_size)
        wf = font(week_path, ws)
        num_w = d.textlength(ds, font=nf)
        sep_w = d.textlength(sep, font=sf)
        week_w = d.textlength(week_text, font=wf)
        if week_after_sep:
            need = num_w + gap + sep_w + gap + 4 + week_w
        else:
            need = num_w + gap + sep_w + gap + week_w
        avail = right_x - x
        if need <= avail:
            break
        # 优先缩间隔，再缩「日」，再缩星期；日号只在明确允许时才缩
        if gap > min_gap:
            gap -= 1
        elif ds_size > min_small:
            ds_size -= 1
        elif ws > min_small:
            ws -= 1
        elif shrink_num and ns > min_day_size:
            ns -= 1
        else:
            break
    fday = font(fday_path, ns)
    day_font = font(day_path, ds_size)
    week_font = font(week_path, ws)

    b = d.textbbox((0, 0), ds, font=fday, anchor="la")
    center = y + (b[1] + b[3]) / 2.0
    dw = d.textlength(ds, font=fday)
    d.text((x, y), ds, font=fday, fill=BLACK, anchor="la")
    bs = d.textbbox((0, 0), sep, font=day_font, anchor="la")
    d.text((x + dw + gap, center - (bs[1] + bs[3]) / 2.0), sep,
           font=day_font, fill=GRAY, anchor="la")
    bw = d.textbbox((0, 0), week_text, font=week_font, anchor="la")
    if week_after_sep:
        sw = d.textlength(sep, font=day_font)
        d.text((x + dw + gap + sw + gap + 4,
                center - (bw[1] + bw[3]) / 2.0), week_text,
               font=week_font, fill=BLACK, anchor="la")
    else:
        d.text((right_x, center - (bw[1] + bw[3]) / 2.0), week_text,
               font=week_font, fill=BLACK, anchor="ra")


# ---------- 图标绘制 ----------
def draw_icon(d, kind, cx, cy, r, col=BLACK):
    """以 (cx,cy) 为中心、半径 r 画天气图标"""
    if kind in ("sun", "partly"):
        d.ellipse([cx - r * 0.42, cy - r * 0.42, cx + r * 0.42, cy + r * 0.42],
                  outline=col, width=max(2, int(r * 0.12)))
        import math
        for a in range(0, 360, 45):
            rad = math.radians(a)
            x1 = cx + math.cos(rad) * r * 0.62
            y1 = cy + math.sin(rad) * r * 0.62
            x2 = cx + math.cos(rad) * r * 0.92
            y2 = cy + math.sin(rad) * r * 0.92
            d.line([x1, y1, x2, y2], fill=col, width=max(2, int(r * 0.1)))
    if kind in ("partly", "cloud", "rain", "snow", "thunder"):
        ox = r * 0.18 if kind == "partly" else 0
        oy = r * 0.12 if kind == "partly" else 0
        d.ellipse([cx - r * 0.55 + ox, cy - r * 0.1 + oy, cx + r * 0.15 + ox, cy + r * 0.5 + oy],
                  fill=WHITE, outline=col, width=max(2, int(r * 0.11)))
        d.ellipse([cx - r * 0.1 + ox, cy - r * 0.35 + oy, cx + r * 0.6 + ox, cy + r * 0.35 + oy],
                  fill=WHITE, outline=col, width=max(2, int(r * 0.11)))
        d.rectangle([cx - r * 0.55 + ox, cy + r * 0.18 + oy, cx + r * 0.6 + ox, cy + r * 0.5 + oy],
                    fill=WHITE, outline=WHITE)
        d.line([cx - r * 0.55 + ox, cy + r * 0.5 + oy, cx + r * 0.6 + ox, cy + r * 0.5 + oy],
               fill=col, width=max(2, int(r * 0.11)))
    if kind == "rain":
        for i in (-1, 0, 1):
            x = cx + i * r * 0.38
            d.line([x, cy + r * 0.62, x - r * 0.08, cy + r * 0.95], fill=col, width=max(2, int(r * 0.1)))
    if kind == "snow":
        for i in (-1, 0, 1):
            x = cx + i * r * 0.4
            y = cy + r * 0.78
            d.line([x - r * 0.16, y - r * 0.16, x + r * 0.16, y + r * 0.16], fill=col, width=max(2, int(r * 0.09)))
            d.line([x - r * 0.16, y + r * 0.16, x + r * 0.16, y - r * 0.16], fill=col, width=max(2, int(r * 0.09)))
    if kind == "thunder":
        d.polygon([(cx - r * 0.22, cy + r * 0.55), (cx + r * 0.05, cy + r * 0.55),
                   (cx - r * 0.06, cy + r * 0.78), (cx + r * 0.26, cy + r * 0.48),
                   (cx - r * 0.02, cy + r * 0.72), (cx - r * 0.22, cy + r * 0.55)], fill=col)
    if kind == "fog":
        for i in range(4):
            y = cy - r * 0.35 + i * r * 0.35
            d.line([cx - r * 0.75, y, cx + r * 0.75, y], fill=col, width=max(2, int(r * 0.09)))


def draw_curve(d, data, at, x0, y0, w, h):
    """未来 12 小时气温折线。返回 True 表示画成功（数据不足时返回 False）。

    区域左上角 (x0,y0)，宽 w 高 h。顶部留 20px 给温度标注，底部留 16px 给小时刻度。
    e-ink 灰度层次少，所以线画粗（3px）、节点画实心圆，避免浅色线条看不清。
    """
    hd = data.get("hourly") or {}
    times = hd.get("time") or []
    temps = hd.get("temperature_2m") or []
    key = at.strftime("%Y-%m-%dT%H:00")
    if key not in times:
        return False
    i0 = times.index(key)
    vals, hrs = [], []
    for k in range(12):
        i = i0 + k
        if i >= len(temps) or temps[i] is None:
            break
        vals.append(float(temps[i]))
        hrs.append(int(times[i][11:13]))
    if len(vals) < 3:
        return False

    lo, hi = min(vals), max(vals)
    if hi - lo < 4:                      # 温差太小会画成直线，人为撑开到 4 度
        mid = (hi + lo) / 2.0
        lo, hi = mid - 2.0, mid + 2.0
    span = max(0.5, hi - lo)

    top = y0 + 20
    bot = y0 + h - 16
    n = len(vals)

    def px(k):
        return x0 + int(round(w * k / (n - 1)))

    def py(v):
        return int(round(bot - (v - lo) / span * (bot - top)))

    for k in range(n - 1):
        d.line([px(k), py(vals[k]), px(k + 1), py(vals[k + 1])], fill=BLACK, width=3)
    for k in range(n):
        x, y = px(k), py(vals[k])
        d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=BLACK)

    f_t = font(FONT_REG, 16)
    # 温度只标四处：首、末、最高、最低，避免挤成一团；白底衬保证在线条附近也清晰
    for k in sorted({0, n - 1, vals.index(max(vals)), vals.index(min(vals))}):
        t = "%d°" % round(vals[k])
        tw = d.textlength(t, font=f_t)
        tx = max(x0, min(px(k) - tw / 2, x0 + w - tw))
        ty = py(vals[k]) - 20
        d.rectangle([tx - 2, ty - 2, tx + tw + 2, ty + 18], fill=WHITE)
        d.text((tx, ty), t, font=f_t, fill=BLACK)

    f_h = font(FONT_REG, 15)
    for k in range(0, n, 2):             # 每 2 小时标一个刻度
        t = str(hrs[k])
        tw = d.textlength(t, font=f_h)
        d.text((px(k) - tw / 2, bot + 3), t, font=f_h, fill=GRAY)
    return True


def compass(deg):
    names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
    return names[int((deg + 22.5) % 360 // 45)]


def greeting(h):
    if 5 <= h < 9:
        return "早上好"
    if 9 <= h < 12:
        return "上午好"
    if 12 <= h < 14:
        return "中午好"
    if 14 <= h < 18:
        return "下午好"
    if 18 <= h < 23:
        return "晚上好"
    return "夜深了"


# ---------- 取数据 ----------
def _ensure_location():
    global LOCATION
    if LOCATION is None:
        LOCATION = resolve_location()
    if LOCATION.get("lat") is None or LOCATION.get("lon") is None:
        raise RuntimeError("无法确定位置：请提供 location.json 或设置 DASH_LAT/DASH_LON")
    return LOCATION


def fetch():
    _ensure_location()
    url = ("https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
           "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m"
           "&hourly=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,precipitation_probability"
           "&daily=weather_code,temperature_2m_max,temperature_2m_min"
           "&timezone=%s&forecast_days=6" % (LOCATION["lat"], LOCATION["lon"], TZ))
    req = urllib.request.Request(url, headers={"User-Agent": "kindle-dash/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def pick_hourly(data, at):
    """取逐小时预报中 at 这一整点的一组值；取不到就返回 None（退回 current）。"""
    h = data.get("hourly") or {}
    times = h.get("time") or []
    key = at.strftime("%Y-%m-%dT%H:00")
    if key not in times:
        return None
    i = times.index(key)
    out = {}
    for k, v in h.items():
        if k == "time":
            continue
        out[k] = v[i] if isinstance(v, list) and i < len(v) else None
    return out


def daily_index(daily, d):
    """按日期在 daily 数组里定位；找不到返回 None。"""
    times = (daily or {}).get("time") or []
    try:
        return times.index(d.isoformat())
    except Exception:
        return None


# ---------- 渲染 ----------
def render(data, out, at=None):
    """at 为 None 表示渲染"此刻"；传入 datetime 则渲染该整点（用于批量预生成）。"""
    _ensure_location()
    now = datetime.datetime.now(TZLOCAL)
    at = at or now
    img = Image.new("L", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    daily = data["daily"]
    cur = pick_hourly(data, at) or data["current"]
    code = cur.get("weather_code")
    desc, kind = WMO.get(code, ("未知", "cloud"))
    temp = cur.get("temperature_2m")
    if temp is None:
        temp = data["current"].get("temperature_2m", 0)

    M = 30                 # 左右统一边距
    RIGHT = W - M          # 内容右边界 570

    # 顶部：城市 + 问候语 | 干支纪年 + 生肖
    # 时钟已移除：本仪表盘每小时才刷新一次，显示分钟级时钟没有意义；
    # 改为几乎不变的干支纪年与生肖，次年生肖随春节自动更替。
    d.text((M, 22), city_label(), font=font(FONT_BOLD, 30), fill=BLACK)
    d.text((M + 2, 60), greeting(at.hour) + "，祝你今天顺利", font=font(FONT_REG, 20), fill=GRAY)
    gz, sheng, gz_year = ganzhi_of(at.date())
    f_gz = font(FONT_BOLD, 40)
    gw = d.textlength(gz, font=f_gz)
    d.text((RIGHT - gw, 14), gz, font=f_gz, fill=BLACK)
    d.text((RIGHT - d.textlength(sheng + "年", font=font(FONT_REG, 22)), 62),
           sheng + "年", font=font(FONT_REG, 22), fill=GRAY)
    d.line([(M, 98), (RIGHT, 98)], fill=LGRAY, width=2)

    # 左：当前天气
    ftemp = font(FONT_BOLD, 96)
    ts = "%d°" % round(temp)
    d.text((M + 4, 122), ts, font=ftemp, fill=BLACK)
    draw_icon(d, kind, 268, 170, 56)
    d.text((M + 4, 240), desc, font=font(FONT_BOLD, 30), fill=BLACK)
    rh = cur.get("relative_humidity_2m")
    ws = cur.get("wind_speed_10m")
    wd = cur.get("wind_direction_10m")
    line = "湿度 %s%%" % (rh if rh is not None else "--")
    if ws is not None:
        line += "   风 %.0f km/h" % ws
        if wd is not None:
            line += " %s" % compass(wd)
    d.text((M + 4, 286), line, font=font(FONT_REG, 20), fill=GRAY)
    pp = cur.get("precipitation_probability")
    if pp is not None:
        d.text((M + 4, 322), "降水概率 %d%%" % int(round(pp)), font=font(FONT_REG, 20), fill=GRAY)

    # 中缝
    d.line([(312, 112), (312, 396)], fill=LGRAY, width=2)

    # 右：日历
    # 用户反馈"距离什么多少天、还有多少周不好看"，倒计时类信息全部撤掉；
    # 腾出来的那块留白用来放**当天的生肖剪影**。
    #
    # 生肖日 = 日支所主的生肖，用干支纪日精确计算（见 zodiac_of_day）。
    # 已与"万年历"App 的干支逐日核对过：11-04 壬午(马)、11-05 癸未(羊)、
    # 11-06 甲申(猴)、11-07 乙酉(鸡)、11-08 丙戌(狗)，完全一致。
    d.text((332, 112), "%d年%d月" % (at.year, at.month),
           font=font(FONT_REG, 24), fill=GRAY)
    st = solar_term_of(at.date())
    # 节气一年只有 24 天，放第一行右端；年月缩到 24px 正好让出位置。
    # 两段字号不同，按各自字形底边对齐基线。
    if st:
        f_tm = font(FONT_REG, 19)
        dy = (d.textbbox((0, 0), "年月", font=font(FONT_REG, 24))[3]
              - d.textbbox((0, 0), "今日", font=f_tm)[3])
        tw = d.textlength("今日 " + st, font=f_tm)
        d.text((RIGHT - tw, 112 + dy), "今日 " + st, font=f_tm, fill=GRAY)
    ds = str(at.day)
    # 竖屏右栏净宽只有 238px，容不下 142px 的大字（用户实测：单个数字会顶到
    # 上面的"2026年11月"，两位数又会被迫降级到 96px，尺寸随日期跳变）。
    # 现在日号固定 104px —— 单双数字完全一致，绝不跳变；
    # 「日」和「星期」这两个小字允许自动收缩来腾空间，日号本身不动。
    # 星期用 week_after_sep（紧跟「日」）而不是右对齐：
    #   双数字时「日」右缘在 475，右对齐的星期左缘在 492，只剩 17px 挤在一起；
    #   改成紧跟后最宽用到 552，右界 570 还余 18px，两种位数都是舒展的。
    big_day(d, 332, 148, ds, FONT_BOLD, 104, FONT_REG, 26,
            WEEK[at.weekday()], FONT_BOLD, 28, RIGHT, sep_gap=6,
            week_after_sep=True, shrink_num=False)
    # 农历行用 22px：给右下角的生肖剪影腾出横向空间（农历到 464，剪影从 468 起）
    # 日号从 142px 缩到 104px 后，右栏上半部空出约 40px，
    # 农历/干支/生肖三行整体上移 24px，让右栏节奏与左栏对齐、底部留白均衡。
    d.text((332, 266), lunar_str(at.date()), font=font(FONT_REG, 22), fill=BLACK)

    # 生肖日：剪影 + 日干支 + 生肖名
    zod, day_gz = zodiac_of_day(at.date())
    if draw_zodiac:
        # 剪影外接框 100x104，居中在右栏右下角（x 468~568），左侧留给文字。
        draw_zodiac(img, d, zod, 518, 330, 100)
    d.text((332, 296), "%s日" % day_gz, font=font(FONT_BOLD, 22), fill=BLACK)
    d.text((332, 326), "生肖 %s" % zod, font=font(FONT_REG, 19), fill=GRAY)

    d.line([(M, 412), (RIGHT, 412)], fill=LGRAY, width=2)

    # 中部：未来 12 小时气温曲线（左右各留边距，末点与标注不贴边）
    if not draw_curve(d, data, at, M + 6, 420, W - 2 * (M + 6), 176):
        d.text((M + 6, 500), "（逐小时气温暂不可用）", font=font(FONT_REG, 19), fill=LGRAY)

    d.line([(M, 610), (RIGHT, 610)], fill=LGRAY, width=2)

    # 下部：未来两天，两列等宽居中（外侧留白一致）
    f_one = font(FONT_REG, 19)
    for col, off in enumerate((1, 2)):
        dd = at.date() + datetime.timedelta(days=off)
        i = daily_index(daily, dd)
        if i is None:
            continue
        try:
            c2 = daily["weather_code"][i]
            dh, dk = WMO.get(c2, ("未知", "cloud"))
            hi = daily["temperature_2m_max"][i]
            lo = daily["temperature_2m_min"][i]
        except Exception:
            continue
        label = ("明天" if off == 1 else WEEK[dd.weekday()])
        txt = "%s %d°/%d° %s" % (label, round(hi), round(lo), dh)
        tw = d.textlength(txt, font=f_one)
        cell_c = M + 135 + col * 270          # 两格各 270 宽，居中于各自格内
        start = cell_c - (54 + tw) / 2
        draw_icon(d, dk, start + 22, 660, 22)
        d.text((start + 54, 660), txt, font=f_one, fill=BLACK, anchor="lm")

    # 底部状态栏：左=「更新 时间」，右侧默认留白（见 show_batt）
    draw_footer(d, M, RIGHT, at)

    img.save(out, "PNG")
    return out


# ---- 底部状态栏右侧：电量显示 ----
#
# 历史（2026-11-04 上午）：曾经把「电量：94」整串写死烧进 PNG；
# 后来改为运行时注入（DASH_BATT / --batt），由 A 方案云端中转提供真实值。
#
# 2026-11-04 中午用户决定：**该位置暂时留白**。
# 原因：电量每小时才随取图更新一次数值，看着反而别扭，不如不展示。
# 处理方式是「默认不绘制」而不是删代码 —— batt_text() 与云端链路都保留，
# 但设备端 12:37 起已停止上报（省电，BATT_REPORT=0），CI 读取步骤也停用。
# 以后想恢复要三处一起开：--show-batt、BATT_REPORT=1、CI 电量读取步骤。
#
# 设备端读电量接口（Probe5 实测确认）留档：
#   lipc-get-prop com.lab126.powerd battLevel   -> 0..100
#   lipc-get-prop com.lab126.powerd isCharging  -> 0/1
# 也可用 sysfs：/sys/class/power_supply/bd7181x_bat/capacity
def show_batt():
    """底部状态栏右侧是否绘制电量。默认 False = 留白。"""
    return (os.environ.get("DASH_SHOW_BATT") or "").strip() in \
        ("1", "true", "True", "yes", "on")


def batt_text():
    v = (os.environ.get("DASH_BATT") or "").strip()
    if not v.isdigit() or not (0 <= int(v) <= 100):
        return "电量：--"
    s = "电量：%d" % int(v)
    if (os.environ.get("DASH_BATT_CHARGING") or "").strip() == "1":
        s += " 充电中"
    return s

# 底部状态栏统一字号：左侧「更新 时间」用 16px；
# 右侧若恢复显示电量，也必须同字号（历史教训：曾 21px 明显偏大）。
FOOTER_FONT_SIZE = 16
BATT_FONT_SIZE = FOOTER_FONT_SIZE   # 保留别名，兼容既有引用

# ---- eips 字符格几何（dash_probe3 v3 实测标定，留档备用）----
#   命令语法: eips [col] [row] "text"
#   col0 字形左缘 x=40；row0 字形顶缘 y=0；列宽 13.65；行高 38.7
#   （20个'8'@row0 最右暗列 x=313 => (313-40-13.65)/19≈13.65；
#     row20 '8' 顶 y=774 => 774/20=38.7）
EIPS_X0 = 40
EIPS_Y0 = 0
EIPS_CELL_W = 13.65
EIPS_CELL_H = 38.7


def draw_footer(d, left_x, right_x, at):
    """底部状态栏：左侧「更新 时间」；右侧默认留白（见 show_batt）。竖屏与横屏共用。"""
    d.text((left_x + 2, BATT_BASE_Y), "更新 " + at.strftime("%m-%d %H:%M"),
           font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="ls")
    if show_batt():
        d.text((right_x, BATT_BASE_Y), batt_text(),
               font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")


# ---------------------------------------------------------------------------
# 横屏版式
#
# Kindle 8 的屏幕物理上就是 600x800 竖屏，固件无自动旋转、也无陀螺仪，
# 所以"横屏"不可能自动感知，只能：
#   1) 云端渲染 800x600 的横版画面，逆时针旋转 90° 后烧成 600x800 的 PNG；
#   2) 用户把 Kindle 横过来拿时，看到的正好是正的。
#
# 横屏的优势是横向空间大：竖屏只放 2 天预报，横屏可以放 5 天。
# ---------------------------------------------------------------------------


def draw_multi_day(d, daily, at, x0, y0, w, h, days=5):
    """横屏用的多日温度带：每天一列，柱状表示最高/最低温，柱顶标最高温。"""
    d.text((x0, y0 - 8), "未来 %d 天" % days, font=font(FONT_BOLD, 20), fill=BLACK)
    # 日期标签行独占一行；柱体从它下面开始，柱顶再留 22px 给最高温标注，
    # 否则标签会和最高温数字压在一起。
    label_y = y0 + 26
    top = y0 + 44
    bot = y0 + h - 30
    colw = w / float(days)

    # 收集数据
    items = []
    for off in range(days):
        dd = at.date() + datetime.timedelta(days=off)
        i = daily_index(daily, dd)
        if i is None:
            continue
        try:
            hi = float(daily["temperature_2m_max"][i])
            lo = float(daily["temperature_2m_min"][i])
            code = daily["weather_code"][i]
        except Exception:
            continue
        items.append((dd, hi, lo, code))
    if not items:
        return

    hi_all = max(t[1] for t in items)
    lo_all = min(t[2] for t in items)
    span = max(1.0, hi_all - lo_all)
    # 柱区上方留 22px 给最高温标注
    bar_top = top + 22
    bar_bot = bot

    for k, (dd, hi, lo, code) in enumerate(items):
        cx = x0 + int(colw * (k + 0.5))
        desc, kind = WMO.get(code, ("未知", "cloud"))
        # 日期标签放最上方（在最高温标注之上），避免与柱体/最低温重叠
        if k == 0:
            label = "今天"
        elif k == 1:
            label = "明天"
        else:
            label = WEEK[dd.weekday()]
        d.text((cx, label_y), label, font=font(FONT_REG, 17), fill=GRAY, anchor="mm")
        # 柱：最高到最低
        y_hi = int(bar_bot - (hi - lo_all) / span * (bar_bot - bar_top))
        d.rectangle([cx - 20, y_hi, cx + 20, bar_bot], fill=WHITE, outline=BLACK, width=2)
        # 上下端小横杠
        d.line([(cx - 24, y_hi), (cx + 24, y_hi)], fill=BLACK, width=3)
        d.line([(cx - 24, bar_bot), (cx + 24, bar_bot)], fill=BLACK, width=3)
        # 最高温标注：贴在柱顶横杠上方
        d.text((cx, y_hi - 6), "%d°" % round(hi), font=font(FONT_BOLD, 17),
               fill=BLACK, anchor="ms")
        # 最低温标注：贴在柱底横杠下方
        d.text((cx, bar_bot + 5), "%d°" % round(lo), font=font(FONT_REG, 15),
               fill=GRAY, anchor="ma")
        # 天气图标：放在柱内中段
        draw_icon(d, kind, cx, (y_hi + bar_bot) / 2, 13)


def render_landscape(data, out, at=None):
    """渲染横屏版：800x600 画面 -> 逆时针旋转 90° -> 600x800 PNG。

    关于底部状态栏：eips 画的文字永远是"竖屏方向正"的，
    在横屏视图里必然躺倒。所以横屏版的状态栏仍然画在竖屏坐标系
    （旋转后的 600x800 画布下方），这样设备端叠加电量数字时
    竖屏/横屏用的是同一组 col/row，一套坐标通吃。
    """
    _ensure_location()
    at = at or datetime.datetime.now(TZLOCAL)

    LW, LH = 800, 600
    img = Image.new("L", (LW, LH), WHITE)
    d = ImageDraw.Draw(img)

    daily = data["daily"]
    cur = pick_hourly(data, at) or data["current"]
    code = cur.get("weather_code")
    desc, kind = WMO.get(code, ("未知", "cloud"))
    temp = cur.get("temperature_2m")
    if temp is None:
        temp = data["current"].get("temperature_2m", 0)

    M = 26
    RIGHT = LW - M

    # 顶栏：城市 + 问候 | 干支 + 生肖
    d.text((M, 12), city_label(), font=font(FONT_BOLD, 28), fill=BLACK)
    d.text((M + 2, 46), greeting(at.hour) + "，祝你今天顺利", font=font(FONT_REG, 19), fill=GRAY)
    gz, sheng, gz_year = ganzhi_of(at.date())
    f_gz = font(FONT_BOLD, 36)
    gw = d.textlength(gz, font=f_gz)
    d.text((RIGHT - gw, 6), gz, font=f_gz, fill=BLACK)
    d.text((RIGHT - d.textlength(sheng + "年", font=font(FONT_REG, 20)), 48),
           sheng + "年", font=font(FONT_REG, 20), fill=GRAY)
    d.line([(M, 78), (RIGHT, 78)], fill=LGRAY, width=2)

    # 左栏：当前天气
    d.text((M + 2, 90), "当前天气", font=font(FONT_REG, 18), fill=GRAY)
    d.text((M + 2, 114), "%d°" % round(temp), font=font(FONT_BOLD, 84), fill=BLACK)
    draw_icon(d, kind, 262, 154, 48)
    d.text((M + 2, 210), desc, font=font(FONT_BOLD, 26), fill=BLACK)
    rh = cur.get("relative_humidity_2m")
    ws = cur.get("wind_speed_10m")
    wd = cur.get("wind_direction_10m")
    line = "湿度 %s%%" % (rh if rh is not None else "--")
    if ws is not None:
        line += "   风 %.0f km/h" % ws
        if wd is not None:
            line += " %s" % compass(wd)
    d.text((M + 2, 248), line, font=font(FONT_REG, 19), fill=GRAY)
    pp = cur.get("precipitation_probability")
    if pp is not None:
        d.text((M + 2, 278), "降水概率 %d%%" % int(round(pp)), font=font(FONT_REG, 19), fill=GRAY)

    # 右栏：日历（与竖屏同一套逻辑：干支生肖 + 当天生肖剪影）
    d.text((392, 90), "日历", font=font(FONT_REG, 18), fill=GRAY)
    st = solar_term_of(at.date())
    d.text((392, 112), "%d年%d月" % (at.year, at.month),
           font=font(FONT_REG, 22), fill=GRAY)
    # 节气放首行右端（与竖屏统一），避免和右下角的剪影抢位置
    if st:
        f_tm = font(FONT_REG, 18)
        dy = (d.textbbox((0, 0), "年月", font=font(FONT_REG, 22))[3]
              - d.textbbox((0, 0), "今日", font=f_tm)[3])
        tw = d.textlength("今日 " + st, font=f_tm)
        d.text((RIGHT - tw, 112 + dy), "今日 " + st, font=f_tm, fill=GRAY)
    ds = str(at.day)
    # 横屏右栏宽 382，星期紧跟「日」而不是右对齐——右对齐会压到剪影。
    # 日号固定 88px（与竖屏同一套"字号固定、只缩小字"的策略），
    # 单双数字高度一致，不会随日期跳变。
    big_day(d, 392, 134, ds, FONT_BOLD, 88, FONT_REG, 26,
            WEEK[at.weekday()], FONT_BOLD, 28, RIGHT, sep_gap=6,
            week_after_sep=True, shrink_num=False)
    # 农历行
    d.text((392, 236), lunar_str(at.date()), font=font(FONT_REG, 21), fill=BLACK)

    # 生肖日：剪影 + 日干支 + 生肖名
    zod, day_gz = zodiac_of_day(at.date())
    if draw_zodiac:
        # 剪影外接框 130，独占右栏右下角（x 620~750 / y 201~331）
        draw_zodiac(img, d, zod, 685, 266, 130)
    d.text((392, 268), "%s日" % day_gz, font=font(FONT_BOLD, 21), fill=BLACK)
    d.text((392, 296), "生肖 %s" % zod, font=font(FONT_REG, 18), fill=GRAY)

    d.line([(M, 336), (RIGHT, 336)], fill=LGRAY, width=2)

    # 下部：多日温度趋势（横屏优势：5 天）
    draw_multi_day(d, daily, at, M, 344, RIGHT - M, 200, days=5)

    # 底部状态栏：画在 800x600 画布的底部条带里，随画面一起旋转，
    # 这样用户横持时它正好在正下方（而不是跟着跑到侧边去）。
    d.line([(M, 552), (RIGHT, 552)], fill=LGRAY, width=2)
    d.text((M + 2, 560), "更新 " + at.strftime("%m-%d %H:%M"),
           font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK)
    # 右侧电量位：2026-11-04 中午起默认留白（用户要求，见 show_batt）。
    # 恢复显示时锚点仍用 "ra"（右对齐 + 顶对齐）与左侧默认的 "la" 齐平：
    # 原来用 "rs"（右对齐 + 基线对齐），同样 y=560 却比左侧低约一个字高。
    if show_batt():
        d.text((RIGHT, 560), batt_text(), font=font(FONT_REG, FOOTER_FONT_SIZE),
               fill=BLACK, anchor="ra")

    # 旋转成 600x800。
    # 用 ROTATE_90（逆时针 90 度）：已用 ASCII 标记实测验证过——
    # 用户把 Kindle 横过来拿（顶端朝右）时，看到的方向正好是正的，
    # 文字不倒、不镜像。
    img = img.transpose(Image.ROTATE_90)

    img.save(out, "PNG")
    return out, (RIGHT, RIGHT)


def city_label():
    """显示用城市名，如「江苏泰州」"""
    c = (LOCATION.get("city") or "").replace("市", "").replace("自治州", "")
    r = (LOCATION.get("region") or "").replace("省", "").replace("市", "")
    if r and c and not c.startswith(r):
        return r + c
    return c or r or "未知位置"


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Kindle 日历天气仪表盘渲染器")
    ap.add_argument("--out", default="dash.png", help="单张输出文件名")
    ap.add_argument("--hours", type=int, default=0,
                    help="批量模式：从当前整点起生成 N 张逐小时图")
    ap.add_argument("--outdir", default=".", help="批量模式输出目录")
    ap.add_argument("--landscape", action="store_true",
                    help="生成横屏版（800x600 画面旋转 90 度后输出 600x800）")
    ap.add_argument("--batt", type=int, default=None,
                    help="设备实测电量 0-100（默认不绘制，需配合 --show-batt）")
    ap.add_argument("--charging", action="store_true",
                    help="设备正在充电，电量后追加「充电中」")
    ap.add_argument("--show-batt", action="store_true",
                    help="在底部状态栏右侧显示电量；默认该位置留白（等价 DASH_SHOW_BATT=1）")
    args = ap.parse_args()

    if args.batt is not None:
        os.environ["DASH_BATT"] = str(args.batt)
    if args.charging:
        os.environ["DASH_BATT_CHARGING"] = "1"
    if args.show_batt:
        os.environ["DASH_SHOW_BATT"] = "1"

    LOCATION = resolve_location()
    print("位置: %s (%s, %s) 来源=%s" % (city_label(), LOCATION.get("lat"),
          LOCATION.get("lon"), LOCATION.get("source")))
    data = fetch()
    print("当前实况: %s°C %s" % (data["current"]["temperature_2m"],
          WMO.get(data["current"]["weather_code"], ("?",))[0]))

    if args.hours > 0:
        base = datetime.datetime.now(TZLOCAL).replace(minute=0, second=0, microsecond=0)
        os.makedirs(args.outdir, exist_ok=True)
        names = []
        for k in range(args.hours):
            at = base + datetime.timedelta(hours=k)
            fn = os.path.join(args.outdir, at.strftime("%Y%m%d_%H") + ".png")
            render(data, fn, at)
            names.append(os.path.basename(fn))
            if args.landscape:
                lf = os.path.join(args.outdir, at.strftime("%Y%m%d_%H") + "_land.png")
                render_landscape(data, lf, at)
                names.append(os.path.basename(lf))
        # 底部状态栏右侧电量位元数据：记录「显示 / 留白」状态，
        # 只为 CI 流程与将来调试留档，内容不再被设备端读取。
        with open(os.path.join(args.outdir, "batt_pos.txt"), "w", encoding="utf-8") as f:
            f.write("# 底部状态栏右侧电量位元数据（当前设备端不读取，仅留档）。\n")
            if show_batt():
                f.write("# 状态：显示，当前文案：%s（由 DASH_BATT / --batt 注入）\n" % batt_text())
            else:
                f.write("# 状态：留白（2026-11-04 用户决定暂不展示每小时变化的电量数值）。\n")
                f.write("#       设备端电量上报已停用（省电）；恢复需 --show-batt + BATT_REPORT=1。\n")
            f.write("# 设备端读电量：lipc-get-prop com.lab126.powerd battLevel / isCharging\n")
            f.write("#\n")
            f.write("# 留档：eips 字符格实测标定值（dash_probe3 v3）\n")
            f.write("#   命令语法 eips [col] [row] \"text\"\n")
            f.write("#   col0 字形左缘 x=%d；row0 字形顶缘 y=%d；列宽 %.2f；行高 %.2f\n"
                    % (EIPS_X0, EIPS_Y0, EIPS_CELL_W, EIPS_CELL_H))
            f.write("#   若将来要恢复设备端实时数字叠加，用这组值换算 col/row 即可。\n")
        # 索引文件：Kindle 抓不到目标图时可据此挑最近的一张
        with open(os.path.join(args.outdir, "index.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(names) + "\n")
        print("批量生成 %d 张 -> %s" % (len(names), os.path.abspath(args.outdir)))
        print("区间: %s ~ %s" % (names[0], names[-1]))
    else:
        if args.landscape:
            out, slot = render_landscape(data, args.out)
        else:
            render(data, args.out)
            slot = (None, None)
        print("OK ->", os.path.abspath(args.out))
        if slot[0] is not None:
            print("电量槽像素范围: x %d..%d" % slot)
