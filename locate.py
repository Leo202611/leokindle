#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
位置探测：生成 location.json，供 render.py 使用。
代码里不含任何城市，城市由「WiFi 映射 -> IP 定位 -> 人工确认」得到，
经纬度由 Open-Meteo 地理编码接口自动解析。

用法：
    python3 locate.py                 # 自动探测，最后让你确认城市
    python3 locate.py --city 泰州      # 直接指定城市（仍自动解析经纬度）
    python3 locate.py --city 泰州 --region 江苏
"""
import json, os, sys, subprocess, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render as R


def current_ssid():
    """取当前 WiFi 名（macOS）"""
    ap = ("/System/Library/PrivateFrameworks/Apple80211.framework"
          "/Versions/Current/Resources/airport")
    try:
        out = subprocess.run([ap, "-I"], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if " SSID:" in line:
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    # Linux/其他：试试 nmcli / iwgetid
    for cmd in (["iwgetid", "-r"], ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=8).stdout
            for line in out.splitlines():
                if line.strip() and ":" in line:
                    if line.startswith("yes:"):
                        return line.split(":", 1)[1].strip()
                elif line.strip():
                    return line.strip()
        except Exception:
            continue
    return None


def load_citymap():
    p = os.path.join(HERE, "citymap.json")
    if os.path.exists(p):
        try:
            return json.load(open(p, encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_citymap(m):
    p = os.path.join(HERE, "citymap.json")
    json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--city", help="直接指定城市名，如 泰州")
    ap.add_argument("--region", help="省/直辖市，用于消歧，如 江苏")
    ap.add_argument("--yes", action="store_true", help="不询问，直接采用自动结果")
    a = ap.parse_args()

    citymap = load_citymap()
    ssid = current_ssid()
    print("当前 WiFi SSID :", ssid or "(取不到)")

    city, region, source = None, None, ""

    # 1) WiFi 映射优先（最准）
    if ssid and ssid in citymap:
        e = citymap[ssid]
        city, region = e.get("city"), e.get("region", "")
        source = "WiFi映射(%s)" % ssid
        print("命中 WiFi 映射  : %s -> %s%s" % (ssid, region, city))

    # 2) IP 定位兜底
    if not city:
        got = R.ip_locate()
        if got and got[0]:
            city, region = got[0], got[1]
            source = "IP定位"
            print("IP 定位结果    : %s%s  (%.4f, %.4f)" % (region, city, got[2], got[3]))
            print("  提示：国内 IP 定位常只到地级市/运营商出口节点，未必是你实际所在城市")

    # 3) 命令行指定 / 人工确认
    if a.city:
        city, region = a.city, (a.region or "")
        source = "手动指定"
    elif not a.yes:
        try:
            ans = input("确认城市（直接回车用「%s」，或输入正确城市名）: " % (region or "") + (city or "")).strip()
        except EOFError:
            ans = ""
        if ans:
            city = ans.replace("市", "").strip()
            region = a.region or ""

    if not city:
        print("未能确定城市，退出")
        sys.exit(1)

    # 4) 用地理编码把城市名解析成精确经纬度 + 标准中文名
    g = R.geocode(city, region)
    if g:
        name, admin1, lat, lon = g
        print("地理编码解析    : %s / %s / %.5f, %.5f" % (name, admin1, lat, lon))
    else:
        print("地理编码失败，改用 IP 坐标")
        got = R.ip_locate()
        name, admin1 = city, region or ""
        lat, lon = (got[2], got[3]) if got else (None, None)

    if lat is None:
        print("无法获得经纬度，退出")
        sys.exit(1)

    loc = {
        "city": name,
        "region": admin1 or region or "",
        "lat": round(lat, 5),
        "lon": round(lon, 5),
        "source": source,
        "ssid": ssid or "",
    }
    out = os.path.join(HERE, "location.json")
    json.dump(loc, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("\n已写入:", out)
    print(json.dumps(loc, ensure_ascii=False, indent=2))

    # 记住 WiFi -> 城市，下次同一网络直接命中
    if ssid:
        citymap[ssid] = {"city": name, "region": admin1 or region or ""}
        save_citymap(citymap)
        print("已记住 WiFi 映射: %s -> %s%s（下次自动命中）" % (ssid, loc["region"], name))


if __name__ == "__main__":
    main()
