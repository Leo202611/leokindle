#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kindle 8 (800x600) 日历 + 天气仪表盘渲染器
数据源：Open-Meteo（免密钥）
输出：8-bit 灰度 PNG，供 Kindle 用 eips -f -g 全屏显示
"""
import json, urllib.request, urllib.parse, datetime, sys, os
from PIL import Image, ImageDraw, ImageFont
from lunardate import LunarDate

# GitHub Actions 等云端服务器用的是 UTC，必须显式按北京时间取"现在"
try:
    from zoneinfo import ZoneInfo
    TZLOCAL = ZoneInfo("Asia/Shanghai")
except Exception:
    TZLOCAL = datetime.timezone(datetime.timedelta(hours=8))

W, H = 800, 600
TZ = "Asia%2FShanghai"

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


def solar_term_date(y, n):
    base = datetime.datetime(1900, 1, 6, 2, 5)
    ms = 31556925974.7 * (y - 1900) + STM[n] * 60000
    return (base + datetime.timedelta(milliseconds=ms) + datetime.timedelta(hours=8)).date()


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


def font(path, size):
    return ImageFont.truetype(path, size)


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

    # 顶部：城市 + 问候语 | 时间
    d.text((30, 24), city_label(), font=font(FONT_BOLD, 30), fill=BLACK)
    d.text((32, 64), greeting(at.hour) + "，祝你今天顺利", font=font(FONT_REG, 20), fill=GRAY)
    t = at.strftime("%H:%M")
    fbig = font(FONT_BOLD, 40)
    d.text((W - 30 - d.textlength(t, font=fbig), 24), t, font=fbig, fill=BLACK)

    d.line([(30, 100), (W - 30, 100)], fill=LGRAY, width=2)

    # 左：当前天气
    ftemp = font(FONT_BOLD, 96)
    ts = "%d°" % round(temp)
    d.text((34, 130), ts, font=ftemp, fill=BLACK)
    draw_icon(d, kind, 300, 190, 62)
    d.text((34, 252), desc, font=font(FONT_BOLD, 32), fill=BLACK)
    rh = cur.get("relative_humidity_2m")
    ws = cur.get("wind_speed_10m")
    wd = cur.get("wind_direction_10m")
    line = "湿度 %s%%" % (rh if rh is not None else "--")
    if ws is not None:
        line += "   风 %.0f km/h" % ws
        if wd is not None:
            line += " %s" % compass(wd)
    d.text((34, 300), line, font=font(FONT_REG, 21), fill=GRAY)
    pp = cur.get("precipitation_probability")
    if pp is not None:
        d.text((34, 348), "降水概率 %d%%" % int(round(pp)), font=font(FONT_REG, 21), fill=GRAY)

    # 中缝
    d.line([(400, 120), (400, 380)], fill=LGRAY, width=2)

    # 右：日历
    d.text((424, 126), "%d年%d月" % (at.year, at.month), font=font(FONT_REG, 24), fill=GRAY)
    fday = font(FONT_BOLD, 132)
    ds = str(at.day)
    d.text((424, 150), ds, font=fday, fill=BLACK)
    dw = d.textlength(ds, font=fday)
    # 「日」与大数字垂直居中对齐、紧贴其后，避免孤立悬浮
    d.text((424 + dw + 6, 150 + (132 - 30) // 2), "日", font=font(FONT_REG, 30), fill=GRAY)
    d.text((424, 300), WEEK[at.weekday()], font=font(FONT_BOLD, 30), fill=BLACK)
    d.text((424, 344), lunar_str(at.date()), font=font(FONT_REG, 23), fill=BLACK)
    st = solar_term_of(at.date())
    if st:
        d.text((424, 380), "今日 " + st, font=font(FONT_REG, 21), fill=GRAY)

    d.line([(30, 406), (W - 30, 406)], fill=LGRAY, width=2)

    # 底部上：未来 12 小时气温曲线（左右各留边距，避免末点/标注贴边）
    if not draw_curve(d, data, at, 40, 414, W - 96, 98):
        d.text((36, 460), "（逐小时气温暂不可用）", font=font(FONT_REG, 19), fill=LGRAY)

    d.line([(30, 520), (W - 30, 520)], fill=LGRAY, width=2)

    # 底部下：未来三天，紧凑横排（小图标 + 一行文字），把竖向空间让给曲线
    f_one = font(FONT_REG, 19)
    for col, off in enumerate((1, 2, 3)):
        x0c = 40 + col * 247
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
        label = ("明天" if off == 1 else "周" + WEEK[dd.weekday()][2])
        draw_icon(d, dk, x0c + 24, 548, 20)
        d.text((x0c + 54, 548), "%s %d°/%d° %s" % (label, round(hi), round(lo), dh),
               font=f_one, fill=BLACK, anchor="lm")

    # 右下角：返回按钮（设备端触摸该区域即退出仪表盘、恢复成普通阅读器）
    bx0, by0, bx1, by1 = 700, 558, 792, 594
    d.rectangle([bx0, by0, bx1, by1], outline=BLACK, width=2)
    fbtn = font(FONT_BOLD, 22)
    tbtn = "返回"
    tw = d.textlength(tbtn, font=fbtn)
    d.text(((bx0 + bx1) / 2, (by0 + by1) / 2), tbtn, font=fbtn, fill=BLACK, anchor="mm")

    d.text((32, 590), "更新 " + at.strftime("%m-%d %H:%M"),
           font=font(FONT_REG, 15), fill=LGRAY, anchor="ls")

    img.save(out, "PNG")
    return out


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
    ap.add_argument("out", nargs="?", default="dash.png", help="单张输出文件名")
    ap.add_argument("--hours", type=int, default=0,
                    help="批量模式：从当前整点起生成 N 张逐小时图")
    ap.add_argument("--outdir", default=".", help="批量模式输出目录")
    args = ap.parse_args()

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
        # 索引文件：Kindle 抓不到目标图时可据此挑最近的一张
        with open(os.path.join(args.outdir, "index.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(names) + "\n")
        print("批量生成 %d 张 -> %s" % (len(names), os.path.abspath(args.outdir)))
        print("区间: %s ~ %s" % (names[0], names[-1]))
    else:
        render(data, args.out)
        print("OK ->", os.path.abspath(args.out))
