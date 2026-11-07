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

# 待机画面每天自动更新的整点。必须与设备端
# /mnt/us/dash/ss_config.sh 的 SS_HOURS 保持一致（2026-11-04 用户定案）。
SS_SLOTS = tuple(range(24))   # 每小时一更：0–23 全时段；与设备端 SS_HOURS 保持一致
TZ = "Asia%2FShanghai"

# 竖屏气温折线覆盖的小时数（含当前整点）。
# 2026-11-06 用户要求 12 -> 24：12 小时恰好在午夜截断、停在降温段末端，
# 看上去像"一路降下去"；24 小时能看到次日清晨最低点之后的回升，构成完整昼夜温差循环。
# 想调回 12（或试 18/36）不必改代码：命令行加 --curve-hours N 即可。
CURVE_HOURS = 24

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
# 各节气当天在问候语后追加的短句（彩蛋）：仅该节气当天出现，其余日子不显示。
TERM_PHRASE = {
    "小寒": "防寒保暖", "大寒": "岁末将尽", "立春": "万物始生", "雨水": "润物无声",
    "惊蛰": "春雷始鸣", "春分": "昼夜均分", "清明": "踏青追思", "谷雨": "雨生百谷",
    "立夏": "万物并秀", "小满": "麦粒渐盈", "芒种": "忙种当时", "夏至": "昼长夜短",
    "小暑": "温风渐至", "大暑": "静心消暑", "立秋": "凉风渐起", "处暑": "暑气渐消",
    "白露": "露凝而白", "秋分": "丹桂飘香", "寒露": "露寒将凝", "霜降": "霜染层林",
    "立冬": "添衣保暖", "小雪": "初雪轻盈", "大雪": "瑞雪兆丰", "冬至": "数九寒天",
}

# 元稹《咏廿四气诗》二十四首「全诗」（五律，每首 4 联 8 句），按节气名索引。
# 每首为 4 个元组，依次是首联(第1、2句)、颔联(第3、4句)、颈联(第5、6句)、尾联(第7、8句)。
# 抬头按「当前节气时段内第几天」轮换 4 联，做到每天不同样、且始终应景。
#
# 【校勘说明】2026-11-07 逐首逐句联网核对，交叉比对 5 个来源：
#   ① 敦煌写卷整理本赏析（微信，学术性最强）② 诗词乐 shicile.com 全集 + 拼音版
#   ③ 中文百科《詠廿四氣詩》繁体全文 ④ 搜狐/瑞文网合集 ⑤ 中华诗词论坛打印帖
# 传世抄本有异文处，取字形在 CJK 基本区、且与《礼记·月令》物候相合者，逐条注明：
#   立春颔联「冰泮游鱼跃」一作「间泮」（取「冰泮」，冰融鱼跃，意通）
#   惊蛰颈联「萌芽互矩修」一作「㸦矩修」「护矩脩」（取多数本「互矩修」）
#   芒种首联「螳螂应节生」一作「螗螂」「螗蜩」（取《月令》「螳螂生」）
#   夏至颔联「龙潜渌水穴」一作「淥水坑」（取「穴」）
#   小满颈联「錋苽竖棘篱」异文最杂：或作「𦬔」「欔」「爪」；「𦬔」属 CJK 扩展 B，
#     Kindle/Noto 字体均无字形会显示方框，故取带注音本之「苽」（同「菰」，基本区）
#   大暑颈联「菰果邀儒客」一作「瓜果」（取多数本「菰果」）
#   立夏颔联「王菰自合生」一作「王瓜」（取多数本「王菰」）
SOLAR_POEM_FULL = {
    "小寒": (("小寒连大吕", "欢鹊垒新巢"), ("拾食寻河曲", "衔紫绕树梢"),
             ("霜鹰近北首", "雊雉隐丛茅"), ("莫怪严凝切", "春冬正月交")),
    "大寒": (("腊酒自盈樽", "金炉兽炭温"), ("大寒宜近火", "无事莫开门"),
             ("冬与春交替", "星周月讵存"), ("明朝换新律", "梅柳待阳春")),
    "立春": (("春冬移律吕", "天地换星霜"), ("冰泮游鱼跃", "和风待柳芳"),
             ("早梅迎雨水", "残雪怯朝阳"), ("万物含新意", "同欢圣日长")),
    "雨水": (("雨水洗春容", "平田已见龙"), ("祭鱼盈浦屿", "归雁过山峰"),
             ("云色轻还重", "风光淡又浓"), ("向春入二月", "花色影重重")),
    "惊蛰": (("阳气初惊蛰", "韶光大地周"), ("桃花开蜀锦", "鹰老化春鸠"),
             ("时候争催迫", "萌芽互矩修"), ("人间务生事", "耕种满田畴")),
    "春分": (("二气莫交争", "春分雨处行"), ("雨来看电影", "云过听雷声"),
             ("山色连天碧", "林花向日明"), ("梁间玄鸟语", "欲似解人情")),
    "清明": (("清明来向晚", "山渌正光华"), ("杨柳先飞絮", "梧桐续放花"),
             ("鴽声知化鼠", "虹影指天涯"), ("已识风云意", "宁愁雨谷赊")),
    "谷雨": (("谷雨春光晓", "山川黛色青"), ("叶间鸣戴胜", "泽水长浮萍"),
             ("暖屋生蚕蚁", "喧风引麦葶"), ("鸣鸠徒拂羽", "信矣不堪听")),
    "立夏": (("欲知春与夏", "仲吕启朱明"), ("蚯蚓谁教出", "王菰自合生"),
             ("帘蚕呈茧样", "林鸟哺雏声"), ("渐觉云峰好", "徐徐带雨行")),
    "小满": (("小满气全时", "如何靡草衰"), ("田家私黍稷", "方伯问蚕丝"),
             ("杏麦修镰钐", "錋苽竖棘篱"), ("向来看苦菜", "独秀也何为")),
    "芒种": (("芒种看今日", "螳螂应节生"), ("彤云高下影", "鴳鸟往来声"),
             ("渌沼莲花放", "炎风暑雨情"), ("相逢问蚕麦", "幸得称人情")),
    "夏至": (("处处闻蝉响", "须知五月中"), ("龙潜渌水穴", "火助太阳宫"),
             ("过雨频飞电", "行云屡带虹"), ("蕤宾移去后", "二气各西东")),
    "小暑": (("倏忽温风至", "因循小暑来"), ("竹喧先觉雨", "山暗已闻雷"),
             ("户牖深青霭", "阶庭长绿苔"), ("鹰鹯新习学", "蟋蟀莫相催")),
    "大暑": (("大暑三秋近", "林钟九夏移"), ("桂轮开子夜", "萤火照空时"),
             ("菰果邀儒客", "菰蒲长墨池"), ("绛纱浑卷上", "经史待风吹")),
    "立秋": (("不期朱夏尽", "凉吹暗迎秋"), ("天汉成桥鹊", "星娥会玉楼"),
             ("寒声喧耳外", "白露滴林头"), ("一叶惊心绪", "如何得不愁")),
    "处暑": (("向来鹰祭鸟", "渐觉白藏深"), ("叶下空惊吹", "天高不见心"),
             ("气收禾黍熟", "风静草虫吟"), ("缓酌樽中酒", "容调膝上琴")),
    "白露": (("露沾蔬草白", "天气转青高"), ("叶下和秋吹", "惊看两鬓毛"),
             ("养羞因野鸟", "为客讶蓬蒿"), ("火急收田种", "晨昏莫辞劳")),
    "秋分": (("琴弹南吕调", "风色已高清"), ("云散飘飖影", "雷收振怒声"),
             ("乾坤能静肃", "寒暑喜均平"), ("忽见新来雁", "人心敢不惊")),
    "寒露": (("寒露惊秋晚", "朝看菊渐黄"), ("千家风扫叶", "万里雁随阳"),
             ("化蛤悲群鸟", "收田畏早霜"), ("因知松柏志", "冬夏色苍苍")),
    "霜降": (("风卷清云尽", "空天万里霜"), ("野豺先祭月", "仙菊遇重阳"),
             ("秋色悲疏木", "鸿鸣忆故乡"), ("谁知一樽酒", "能使百秋亡")),
    "立冬": (("霜降向人寒", "轻冰渌水漫"), ("蟾将纤影出", "雁带几行残"),
             ("田种收藏了", "衣裘制造看"), ("野鸡投水日", "化蜃不将难")),
    "小雪": (("莫怪虹无影", "如今小雪时"), ("阴阳依上下", "寒暑喜分离"),
             ("满月光天汉", "长风响树枝"), ("横琴对渌醑", "犹自敛愁眉")),
    "大雪": (("积阴成大雪", "看处乱霏霏"), ("玉管鸣寒夜", "披书晓绛帷"),
             ("黄钟随气改", "鴳鸟不鸣时"), ("何限苍生类", "依依惜暮晖")),
    "冬至": (("二气俱生处", "周家正立年"), ("岁星瞻北极", "舜日照南天"),
             ("拜庆朝金殿", "欢娱列绮筵"), ("万邦歌有道", "谁敢动征边")),
}
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


def current_solar_term_info(d):
    """返回 (节气时段名, 该时段起始日)。

    24 节气把一年切成 24 段，每段从某个节气当日开始、到下一个节气前结束。
    这样全年每天都能对应一首诗，并在每个节气交界处自动轮换，
    而不是只有 24 天有诗。d 早于当年小寒时属上一年冬至时段。
    """
    best_n, best_date = None, None
    for n in range(24):
        sd = solar_term_date(d.year, n)
        if sd <= d and (best_date is None or sd > best_date):
            best_n, best_date = n, sd
    if best_n is None:
        return "冬至", solar_term_date(d.year - 1, 23)
    return SOLAR[best_n], best_date


def current_solar_term_period(d):
    """返回包含日期 d 的「节气时段」名（24 时段之一，小寒起算）。"""
    return current_solar_term_info(d)[0]


def poem_for(at):
    """左上角抬头：返回 (诗歌名, 当日联句)。

    - 诗按「当前节气时段」选，节气交界自动换下一首，始终应景；
    - 该首 4 联按**节气内第几天**轮换：第1天首联(第1、2句)→第2天颔联
      (第3、4句)→第3天颈联(第5、6句)→第4天尾联(第7、8句)→第5天回首联，
      相邻两天必不同；每个新节气都从首联重新开始。
    - 同一天内所有整点渲染完全一致（按 date 计算，与 hour 无关），
      因为屏保每小时更新但诗句是「每天不同样」。
    - 例：立冬十月节首日「霜降向人寒，轻冰渌水漫」，次日「蟾将纤影出，雁带几行残」。
    - 标题只返回节气名（如「立冬」）：作者「元稹」、集合名「咏廿四气诗」、书名号
      都是 24 首共用的固定信息（用户 2026-11-07 定：每首都显示就没必要显示），
      省掉后正好与右侧「丙午」同为 2 字 40px，左右严格对称。
    """
    d = at.date()
    term, start = current_solar_term_info(d)
    couplets = SOLAR_POEM_FULL.get(term)
    if not couplets:
        return "", ""
    a, b = couplets[(d - start).days % 4]
    return term, a + "，" + b


_GOLD_CACHE = None
def fetch_gold_cny():
    """上海黄金交易所 Au(T+D) 最新价与昨结算（元/克），取自新浪行情（免 token）。
    返回 (最新价, 昨结算)；失败/无数据/基准异常返回 (price, None)。进程内缓存，
    避免 CI 批量渲染时反复请求。

    【2026-11-08 修正字段下标】此前误取 [4] 当最新价、[5] 当昨收，导致屏保上
    「今日金价」显示的是当日**最高价**、「较昨日」显示的是**日内最高−最低振幅**，
    与真实涨跌毫无关系。现改为：
      [0] = 最新价；[7] = 昨结算（涨跌基准）
    实抓样本（2026-11-07 02:29:52）：
      872.50,0,872.50,873.00,873.50,862.23,02:29:52,868.08,871.20,8186,3.00,10.00,...
    校勘依据（新浪官方源码 + 上金所官方行情，2026-11-08 核实）：
      ① 新浪贵金属频道 finance.sina.com.cn/nmetal/ → AUTD 行情页
         finance.sina.com.cn/futures/quotes/AUTD.shtml 所加载的
         n.sinaimg.cn/finance/futures/stock20190814.js 中，现货(gds_, case 7)定义为：
             price = arr[1] ; amt = (arr[1]-arr[8])/arr[8]*100
         而 stock2.finance.sina.com.cn/futures/page2012/js/stockhq.js 会先
             unshift(code) 把代码插入数组头部，故 arr[i] = 原始 f[i-1]
         ⇒ arr[1]=f[0] 最新价、arr[8]=f[7] 昨结算，涨跌幅正是
           (最新价−昨结算)/昨结算 —— 与本函数口径完全一致。
      ② 用实抓串代入官方公式：(872.50−868.08)/868.08 = +0.51%，
         与本函数 +4.42(+0.51%) 吻合。
      ③ 上金所官网 sge.com.cn/sjzx/quotation_daily_new 的 2026-11-06
         Au(T+D) 官方收盘价 868.08，与 [7] 精确一致（权威交叉验证）。
      ④ AUTD 行情页字段名亦明确列出「最新价/昨结算/开盘价/最高价/最低价」。
    为防字段变动或脏数据，下面仍对基准做合理性校验（须为正、且与最新价偏离
    不超过 20%），异常时宁可只显示最新价、不显示涨跌行。
    """
    global _GOLD_CACHE
    if _GOLD_CACHE is not None:
        return _GOLD_CACHE
    price = settle = None
    try:
        req = urllib.request.Request(
            "https://hq.sinajs.cn/list=gds_AUTD",
            headers={"Referer": "https://finance.sina.com.cn",
                     "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read().decode("gbk", "ignore")
        parts = body.split('"')
        if len(parts) >= 2:
            f = parts[1].split(",")
            if len(f) > 7:
                price = float(f[0])
                try:
                    settle = float(f[7])
                except Exception:
                    settle = None
                # 防呆：基准非正、或与最新价偏离过大（字段语义变化/脏数据）则不显示涨跌
                if settle is not None and (
                        settle <= 0 or abs(price - settle) / settle > 0.20):
                    settle = None
    except Exception:
        price = settle = None
    if price is not None:
        _GOLD_CACHE = (price, settle)
    return price, settle


# 油价已移除（用户 2026-11-07 决定）：发改委约每 10 个工作日才调一次、且分省，
# 屏保上近乎静止、意义不大；用户实际加 95#，默认 92# 更显无关。如将来要恢复，
# 用「调价窗口」硬编表（参考数据 2026-11-07：江苏 92#8.85 / 95#9.41 / 0#8.55 元/升）。


# 【2026-11-07 已移除 weather_tip()】曾把「天气衍生生活提示」放在左上角，
# 但用户指出它与中部天气区重复、且口径不一致（提示取未来48h降水概率最大值，
# 中部显示的是当前值），故整段删除。左上角已改回元稹《咏廿四气诗》诗句轮换，
# 与天气数据完全解耦，不会再出现两处数字对不上的情况。


def draw_gold_price(d, right_x, top_y, d_date):
    """方案2（2026-11-07 定案）：『今日金价』抬高一行、涨跌行与左侧『更新』同基线；
    两行右对齐、字号均与『更新』一致(FOOTER_FONT_SIZE=16)。取不到金价显示「金价 --」单行；
    取到金价但无有效昨结算则只显示『今日金价』一行(落同基线，不悬空)。
    【2026-11-08】涨跌基准改为**昨结算**，文案「较昨日」→「较昨结算」
    （Au(T+D) 是延期合约，官方涨跌口径为较昨结算；且有夜盘归属次一交易日、
     周末休市，「昨日」概念模糊）。数值取 [0]最新价 − [7]昨结算，见 fetch_gold_cny。
    注：e-ink 为灰度，无法用红/绿区分涨跌，以 +/- 号 + 数值表达。"""
    g, settle = fetch_gold_cny()
    if g is None:
        d.text((right_x, top_y), "金价 --", font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")
        return
    if settle is not None and settle != 0:
        d.text((right_x, top_y - 30), "今日金价：%.1f元/克" % g,
               font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")
        delta = g - settle
        pct = delta / settle * 100.0
        sign = "+" if delta >= 0 else "-"
        line = "较昨结算：%s%.1f（%s%.2f%%）" % (sign, abs(delta), sign, abs(pct))
        # 极端大波动时文案变长，可能挤到中央电量：超过预留宽度就省去百分比，
        # 只留涨跌额（金价单日 >10% 极罕见，宁可少一字也不撞字）。
        if d.textlength(line, font=font(FONT_REG, FOOTER_FONT_SIZE)) > 220:
            line = "较昨结算：%s%.1f" % (sign, abs(delta))
        d.text((right_x, top_y), line,
               font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")
    else:
        d.text((right_x, top_y), "今日金价：%.1f元/克" % g,
               font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")


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
    """未来 CURVE_HOURS 小时（默认 24）气温折线。返回 True 表示画成功。

    区域左上角 (x0,y0)，宽 w 高 h。
    顶部留约 46px：上 18px 是粒度标题带（"未来 N 小时 · 逐时气温"），
    其下约 20px 留给最高温标注，二者垂直错开避免重叠（早期版本两带重叠，
    峰值恰在标题水平范围内时标题会把最高温数字压住）；
    底部留 16px 给小时刻度。
    e-ink 灰度层次少，所以线画粗（3px）、节点画实心圆，避免浅色线条看不清。

    2026-11-06 用户要求 12h -> 24h：24 点横跨一个完整昼夜，能看到次日清晨
    最低点之后的回升；横轴在跨天处画浅灰虚线并标「明」，避免 23->1 被误读。
    """
    hd = data.get("hourly") or {}
    times = hd.get("time") or []
    temps = hd.get("temperature_2m") or []
    key = at.strftime("%Y-%m-%dT%H:00")
    if key not in times:
        return False
    i0 = times.index(key)
    vals, hrs = [], []
    for k in range(CURVE_HOURS):
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

    top = y0 + 46               # 顶部留 46px 带：标题(上18) + 峰值标注(其下~20) 垂直错开
    bot = y0 + h - 16
    n = len(vals)

    def px(k):
        return x0 + int(round(w * k / (n - 1)))

    def py(v):
        return int(round(bot - (v - lo) / span * (bot - top)))

    # 跨天边界（小时数由 23 回到 0 的位置）：画断续浅灰竖线作视觉分隔。
    # 若边界恰好落在曲线末点（例如 12h 从 13 点起、末点就是次日 0 点），
    # 后面没有「次日段」，统一视为无跨天，避免出现无意义的虚线和「明0」标记。
    day_break = None
    for k in range(1, n):
        if hrs[k] < hrs[k - 1]:
            day_break = k
            break
    if day_break is not None and day_break >= n - 1:
        day_break = None
    if day_break is not None:
        xb = px(day_break)
        yy = top
        while yy < bot:
            d.line([(xb, yy), (xb, min(yy + 5, bot))], fill=LGRAY, width=1)
            yy += 11

    for k in range(n - 1):
        d.line([px(k), py(vals[k]), px(k + 1), py(vals[k + 1])], fill=BLACK, width=3)
    for k in range(n):
        x, y = px(k), py(vals[k])
        d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=BLACK)

    f_t = font(FONT_REG, 16)
    # 温度只标四处：首、末、最高、最低，避免挤成一团；白底衬保证在线条附近也清晰。
    # 24 点的点距只有约 23px，相邻标注会重叠，故按 x 排序后跳过过近者。
    last_tx = -999
    for k in sorted({0, n - 1, vals.index(max(vals)), vals.index(min(vals))}):
        t = "%d°" % round(vals[k])
        tw = d.textlength(t, font=f_t)
        tx = max(x0, min(px(k) - tw / 2, x0 + w - tw))
        if tx - last_tx < 34:
            continue
        last_tx = tx
        # 低温点贴着 bot，标注若照 py-20 画会压到下面的小时刻度行；
        # 统一把标注上抬到 bot-30 以内，保证与刻度至少留一段白。
        ty = max(top - 20, min(py(vals[k]) - 20, bot - 30))
        d.rectangle([tx - 2, ty - 2, tx + tw + 2, ty + 18], fill=WHITE)
        d.text((tx, ty), t, font=f_t, fill=BLACK)

    f_h = font(FONT_REG, 15)
    # 24 小时点距约 23px，每 3 小时标一个刻度（8 个）才不挤；
    # 再补上末点刻度，让「未来 24 小时」的终点有明确时间。
    ticks = list(range(0, n, 3))
    if day_break is not None and n - 1 - ticks[-1] >= 2:
        ticks.append(n - 1)
    # 跨天后的第一个刻度前加「明」，例如「明1」表示次日 1 点；只加一次。
    tomorrow_marked = False
    for k in ticks:
        t = str(hrs[k])
        if day_break is not None and k >= day_break and not tomorrow_marked:
            t = "明" + t
            tomorrow_marked = True
        tw = d.textlength(t, font=f_h)
        d.text((px(k) - tw / 2, bot + 3), t, font=f_h, fill=GRAY)

    # 粒度标签：明确这是「未来 N 小时 · 逐时」，与下方「明天/后天」逐日摘要
    # 属于不同分辨率，避免被误读成同一条时间轴、进而觉得「天数对不上」。
    # 放在曲线区顶部居中的专属标题带（y0+2 起、约 18px 高）：上方不再与曲线
    # 绘图区重叠——draw_curve 已把 top 下移到 y0+46，峰值温度标注落在标题带
    # 下方（top-20），二者垂直错开，不会再出现标题压住最高温的旧问题。
    # 白底衬保证标题在任何背景下都清晰。
    f_lab = font(FONT_REG, 14)
    lab = "未来 %d 小时 · 逐时气温" % CURVE_HOURS
    lw = d.textlength(lab, font=f_lab)
    lx = x0 + (w - lw) / 2.0
    ly = y0 + 2
    d.rectangle([lx - 4, ly - 2, lx + lw + 4, ly + 18], fill=WHITE)
    d.text((lx, ly), lab, font=f_lab, fill=GRAY)
    return True


def compass(deg):
    names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
    return names[int((deg + 22.5) % 360 // 45)]


def greeting(h, term=""):
    # 整句问候按「时段」给出不同祝福，而非只换时段词、后缀恒为"祝你今天顺利"。
    # 深夜避免说"今天"（已是次日），改为"明天见"更自然。
    # term：若当天是二十四节气之一（由 solar_term_of 给出名），则在其后追加一句
    # 应景短句（见 TERM_PHRASE），仅该节气当天出现，其余日子不显示。
    if 5 <= h < 9:
        base = "早上好，新的一天元气满满"
    elif 9 <= h < 12:
        base = "上午好，做事从容些"
    elif 12 <= h < 14:
        base = "中午好，记得好好吃饭"
    elif 14 <= h < 18:
        base = "下午好，忙里偷闲喝口水"
    elif 18 <= h < 23:
        base = "晚上好，今天辛苦啦"
    else:
        base = "夜深了，早点休息，明天见"
    if term:
        ph = TERM_PHRASE.get(term)
        if ph:
            return base + " · 今日" + term + "，" + ph
    return base


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
    # 页眉左右严格对称（2026-11-07 用户定案）：
    #   主行：左上节气名 与 右上干支 —— 同为 2 字、同字号 40、同纯黑、同一水平线 y=14
    #   次行：左下诗句 与 右下生肖 —— 同字号 22、同灰度、同一水平线 y=62
    #   （作者/集合名/书名号均为 24 首共用固定信息，已省略不显示）
    poem_title, poem_line = poem_for(at)
    gz, sheng, gz_year = ganzhi_of(at.date())
    f_gz = font(FONT_BOLD, 40)
    f_sub = font(FONT_REG, 22)
    d.text((M, 14), poem_title, font=f_gz, fill=BLACK)
    d.text((RIGHT - d.textlength(gz, font=f_gz), 14), gz, font=f_gz, fill=BLACK)
    d.text((M, 62), poem_line, font=f_sub, fill=GRAY)
    d.text((RIGHT - d.textlength(sheng + "年", font=f_sub), 62),
           sheng + "年", font=f_sub, fill=GRAY)
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

    # 中部：未来 24 小时（整点）气温曲线（左右各留边距，末点与标注不贴边）
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
# 2026-11-04 中午「右下角电量位留白」与 12:37「停掉每小时上报」曾是省电决定。
# 2026-11-07 用户改为在底栏**中央**显示电量，并恢复上报（改为「搭车上报」：
# 设备整点取图时 WiFi 已开，顺手 POST，零额外唤醒、不恢复 :35 跟进取图）。
# 于是右下角 show_batt() 那套仍保持默认留白/显示金价；中央由新的
# center_batt_text() / draw_batt_center() 独立控制，只看 DASH_BATT 是否注入。
#
# 设备端读电量接口（Probe5 实测确认）留档：
#   lipc-get-prop com.lab126.powerd battLevel   -> 0..100
#   lipc-get-prop com.lab126.powerd isCharging  -> 0/1
#   /sys/class/power_supply/bd7181x_bat/capacity
#   /usr/bin/powerd_test -s（HA 屏保方案的启发，第三条兜底）
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


def center_batt_text():
    """底栏中央电量文案（2026-11-07 新增）：如「电量 83%」。
    与右侧 show_batt() 那套完全独立——中央由 DASH_BATT 是否有效决定，
    有效才画，无效则整块留白（设备离线/上报过期时宁可不画，也不显示 --）。
    数据来自设备整点取图时「搭车」上报到 ntfy、CI 读回后注入的 DASH_BATT，
    故数值约滞后 1 小时；电量是慢变量(约0.3%/小时)，整数显示下误差 <1%，无感。"""
    v = (os.environ.get("DASH_BATT") or "").strip()
    if not v.isdigit() or not (0 <= int(v) <= 100):
        return ""
    return "电量 %d%%" % int(v)


def draw_batt_center(d, cx, y, anchor="ms"):
    """底栏正中央绘制电量百分比，与「更新」「较昨日」同字号、同一水平线。
    竖屏底栏用基线锚点（ls/rs）→ 传 'ms'；横屏底栏用顶部锚点（默认/ra）→ 传 'ma'。
    竖屏 cx=W/2、横屏 cx=LW/2。
    中央空档实测：竖屏 x=172..364(192px)、横屏 396px，文案仅约 73px，绝不撞左右。"""
    t = center_batt_text()
    if t:
        d.text((cx, y), t, font=font(FONT_REG, FOOTER_FONT_SIZE),
               fill=GRAY, anchor=anchor)


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
    """底部状态栏：左「更新 时间」/ 中央「电量 N%」/ 右金价（方案2两行）。竖屏专用。
    中央电量独立于右侧的 show_batt() 开关，由 DASH_BATT 是否注入决定（见 draw_batt_center）。"""
    d.text((left_x + 2, BATT_BASE_Y), "更新 " + at.strftime("%m-%d %H:%M"),
           font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="ls")
    draw_batt_center(d, W / 2, BATT_BASE_Y)
    if show_batt():
        d.text((right_x, BATT_BASE_Y), batt_text(),
               font=font(FONT_REG, FOOTER_FONT_SIZE), fill=BLACK, anchor="rs")
    else:
        draw_gold_price(d, right_x, BATT_BASE_Y, at.date())


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
    """横屏「未来 N 天」温度趋势：与竖屏同一套「点 + 线」语言。

    2026-11-04 用户要求：横屏不要一根根矩形柱，改成竖屏那样点线相连的气温
    趋势。这里画两条折线表达未来几天的温度变化：
      * 上方折线 = 每日最高温，3px 实线 + 实心圆节点，点上方标温度；
      * 下方折线 = 每日最低温，3px 实线 + 空心圆节点，点下方标温度；
      * 每天一条浅灰细竖线连接上下两点，表示当日温度区间（替代原来的柱子）。
    顶部保留「今天/明天/星期X」+ 天气小图标。
    e-ink 灰度层次少，不用颜色区分两条线，改用实心/空心节点区分。
    """
    d.text((x0, y0 - 2), "未来 %d 天" % days, font=font(FONT_BOLD, 20), fill=BLACK)
    d.text((x0 + 130, y0 + 2), "上线 最高温   下线 最低温",
           font=font(FONT_REG, 15), fill=GRAY)

    # 收集数据；off 是真实日偏移，缺失的天留空但列位置不动，避免版式跳动
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
        items.append((off, dd, hi, lo, code))
    if not items:
        d.text((x0, y0 + 60), "（多日预报暂不可用）", font=font(FONT_REG, 19), fill=LGRAY)
        return

    hi_all = max(t[2] for t in items)
    lo_all = min(t[3] for t in items)
    # 温差太小会把两条线压成一条，人为撑开到至少 4 度（与竖屏 draw_curve 一致）
    if hi_all - lo_all < 4:
        mid = (hi_all + lo_all) / 2.0
        lo_all, hi_all = mid - 2.0, mid + 2.0
    span = max(0.5, hi_all - lo_all)

    colw = w / float(days)
    label_y = y0 + 34       # 日期 + 天气图标行
    top = y0 + 76           # 折线区上沿（给最高温标注留 22px）
    bot = y0 + h - 38       # 折线区下沿（给最低温标注留空间）

    def px(off):
        return x0 + int(round(colw * (off + 0.5)))

    def py(v):
        return int(round(bot - (v - lo_all) / span * (bot - top)))

    # 1) 顶部：天气图标 + 日期标签（同一行，整组居中于该列）
    f_lab = font(FONT_REG, 17)
    for off, dd, hi, lo, code in items:
        cx = px(off)
        label = "今天" if off == 0 else ("明天" if off == 1 else WEEK[dd.weekday()])
        _, kind = WMO.get(code, ("未知", "cloud"))
        tw = d.textlength(label, font=f_lab)
        iw, gap = 22, 6
        sx = cx - (iw + gap + tw) / 2.0
        draw_icon(d, kind, sx + iw / 2.0, label_y, 11)
        d.text((sx + iw + gap, label_y), label, font=f_lab, fill=GRAY, anchor="lm")

    # 2) 当日温度区间：浅灰细竖线（先画，让黑色折线压在上面）
    for off, dd, hi, lo, code in items:
        cx = px(off)
        d.line([(cx, py(hi)), (cx, py(lo))], fill=LGRAY, width=1)

    # 3) 两条折线：3px 粗线与竖屏 draw_curve 完全一致
    for idx, key in ((2, "hi"), (3, "lo")):
        pts = [(px(t[0]), py(t[idx])) for t in items]
        for k in range(len(pts) - 1):
            d.line([pts[k], pts[k + 1]], fill=BLACK, width=3)

    # 4) 节点：最高温实心、最低温空心（白心黑边，不依赖灰度区分）
    for off, dd, hi, lo, code in items:
        x, yh, yl = px(off), py(hi), py(lo)
        d.ellipse([x - 4, yh - 4, x + 4, yh + 4], fill=BLACK)
        d.ellipse([x - 4, yl - 4, x + 4, yl + 4], fill=WHITE, outline=BLACK, width=2)

    # 5) 温度标注：白底衬保证压在线条附近也清晰（竖屏同一做法）
    f_hi = font(FONT_BOLD, 16)
    f_lo = font(FONT_REG, 15)
    for off, dd, hi, lo, code in items:
        cx = px(off)
        for val, y, f, col, above in ((hi, py(hi), f_hi, BLACK, True),
                                     (lo, py(lo), f_lo, GRAY, False)):
            t = "%d°" % round(val)
            tw = d.textlength(t, font=f)
            tx = max(x0, min(cx - tw / 2.0, x0 + w - tw))
            ty = y - 22 if above else y + 6
            d.rectangle([tx - 2, ty - 2, tx + tw + 2, ty + 19], fill=WHITE)
            d.text((tx, ty), t, font=f, fill=col)


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
    # 页眉左右严格对称（横屏版，同竖屏规则）：
    #   主行：左上节气名 与 右上干支 —— 36px / 纯黑 / y=6
    #   次行：左下诗句 与 右下生肖 —— 20px / 灰度 / y=48
    poem_title, poem_line = poem_for(at)
    gz, sheng, gz_year = ganzhi_of(at.date())
    f_gz = font(FONT_BOLD, 36)
    f_sub = font(FONT_REG, 20)
    d.text((M, 6), poem_title, font=f_gz, fill=BLACK)
    d.text((RIGHT - d.textlength(gz, font=f_gz), 6), gz, font=f_gz, fill=BLACK)
    d.text((M, 48), poem_line, font=f_sub, fill=GRAY)
    d.text((RIGHT - d.textlength(sheng + "年", font=f_sub), 48),
           sheng + "年", font=f_sub, fill=GRAY)
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
    draw_batt_center(d, LW / 2, 560, "ma")
    # 右侧电量位：2026-11-04 中午起默认留白（用户要求，见 show_batt）。
    # 留白时改放「实时金价」；若开启电量显示则让回电量。
    if show_batt():
        d.text((RIGHT, 560), batt_text(), font=font(FONT_REG, FOOTER_FONT_SIZE),
               fill=BLACK, anchor="ra")
    else:
        draw_gold_price(d, RIGHT, 560, at.date())

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
    ap.add_argument("--curve-hours", type=int, default=0,
                    help="气温折线覆盖的整点数（默认 24；设 12 可回到旧版式）")
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

    # 这里是模块顶层（非函数内），直接赋值即可改全局常量
    if args.curve_hours > 0:
        CURVE_HOURS = args.curve_hours

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

        # 待机画面「当前应显示的槽位」：取最近一次已发生的更新点。
        # 每小时一更下，最近一次 = 当前小时（如 20:58 补刷应显示 20:00 画面，
        # 而不是 21:00 的实时图）。
        # 过去小时的逐小时图已被滚动窗口清掉，不能用 out/ 里的 PNG 复制，
        # 必须用同一份 data 现场渲染任意时刻（render() 支持 at 参数）。
        past = [s for s in SS_SLOTS if s <= base.hour]
        if past:
            slot_at = base.replace(hour=max(past))
        else:
            slot_at = (base - datetime.timedelta(days=1)).replace(hour=max(SS_SLOTS))
        render(data, os.path.join(args.outdir, "ss_prev.png"), slot_at)
        print("当前应显示槽位: %s -> ss_prev.png" % slot_at.strftime("%m-%d %H:00"))

        # 底部状态栏电量位元数据：只为 CI 流程与将来调试留档，设备端不读取。
        with open(os.path.join(args.outdir, "batt_pos.txt"), "w", encoding="utf-8") as f:
            f.write("# 底部状态栏电量位元数据（当前设备端不读取，仅留档）。\n")
            f.write("# 2026-11-07 起：电量显示在底栏【中央】，由 DASH_BATT 是否注入决定；\n")
            f.write("# 右下角仍显示金价（show_batt() 默认 False，不再用于电量）。\n")
            cb = center_batt_text()
            if cb:
                f.write("# 状态：中央显示「%s」；右侧电量位：%s\n"
                        % (cb, "显示" if show_batt() else "留白（显示金价）"))
            else:
                f.write("# 状态：中央留白（无有效上报/设备离线），绝不伪造数字。\n")
            f.write("# 链路：ss_update_once.sh report_batt 搭车 POST -> ntfy -> batt_relay.py\n")
            f.write("#       -> DASH_BATT/--batt -> 烧进整套 PNG（约滞后 1h）。\n")
            f.write("# 设备端读电量：lipc-get-prop com.lab126.powerd battLevel / isCharging\n")
            f.write("#   兜底：sysfs capacity；/usr/bin/powerd_test -s\n")
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
