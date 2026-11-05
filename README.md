# kindle-dash

给越狱 Kindle 8（800×600）用的日历 + 天气仪表盘图片生成器。

- 数据源：[Open-Meteo](https://open-meteo.com)（免费、无需密钥）
- **城市不写死在代码里**，由 WiFi 映射 / IP 定位自动确定，经纬度由地理编码接口解析
- 每 30 分钟由 GitHub Actions 自动渲染一次
- 产物发布到 `dash` 分支的 `dash.png`
- 中文由 Noto Sans CJK（CI 环境自动安装）渲染
- 农历由 `lunardate` 换算，二十四节气自动判定

## 取图地址

```
https://raw.githubusercontent.com/<用户名>/<仓库名>/dash/dash.png
```

## 手动触发

仓库顶部 **Actions** → 左侧 **Render Kindle Dashboard** → **Run workflow**

## 文件

| 文件 | 说明 |
|---|---|
| `render.py` | 渲染器，输出 800×600 8-bit 灰度 PNG |
| `location.json` | 位置配置（由 `locate.py` 生成） |
| `locate.py` | 位置探测：WiFi 映射 → IP 定位 → 人工确认 → 地理编码解析经纬度 |
| `requirements.txt` | Pillow、lunardate |
| `.github/workflows/dash.yml` | 定时任务 |

## 本地预览

```sh
pip install -r requirements.txt
python3 locate.py --city --region    # 生成 location.json
python3 render.py dash.png
```

## 位置优先级

1. 环境变量 `DASH_CITY` / `DASH_REGION` / `DASH_LAT` / `DASH_LON`
2. `location.json`
3. 运行时 IP 定位（精度可能只到地级市）
