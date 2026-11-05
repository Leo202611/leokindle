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

---

## Kindle 待机画面自动更新（linkss 屏保 + 定时换图）

把上面的仪表盘图设成 Kindle 锁屏/休眠屏保，并按固定频率自动换图。依赖
[ScreenSavers Hack（linkss）](https://github.com/NiLuJe/KindleTool) 接管休眠屏保，图片为
**600×800 8-bit 灰度 PNG**，命名 `bg_ss00.png`，放在 `/mnt/us/linkss/screensavers/`。

### 两种模式：阶段1（省事）/ 阶段2（省电）

| 模式 | 开关 | 行为 | 续航 | 风险 |
|---|---|---|---|---|
| 阶段1（回退兜底） | `SS_RTC=0` | 后台常驻 + `deferSuspend` 轻眠，每整点自动换图 | 约 1–2 天 | 低，功能稳 |
| 阶段2（**现默认**） | `SS_RTC=1` | 监听 `readyToSuspend`→`rtcWakeup` 设闹钟→关 WiFi→**真·深睡**；整点唤醒取图刷屏再睡 | 目标不接电源撑一周 | **2026-11-06 真机验证通过** |

> **默认配置（2026-11-06 起）**：`SS_RTC=1`（阶段2 深睡）+ `SS_WIFI_DANCE=1`（模拟电源键重连 WiFi）。
> 两项都是干净部署的开箱值，无需点任何开关。想退回阶段1，KUAL「**11 阶段2深睡:关**」即可
> （每小时仍自动换图，续航 1–2 天）。

更新频率由 `SS_HOURS` 控制（默认 `0 1 2 … 23` 即每小时；想更省电可改成 `0 6 9 12 15 18` 等，写在 `ss_config.local` 即可）。

### WiFi 部署（设备侧，无需数据线/终端）

在 KUAL 里进「气象仪表盘 Dash」菜单，依次点：

1. **5 在线更新(WiFi) - 拉新菜单** — 从 GitHub 拉最新脚本 + 菜单
   （设备连不上 Mac 本地服务时会有约 3 秒超时，随后自动回退 GitHub，属正常）
2. **3 停用定时更新**
3. **1 启用定时更新(每整点)** — 即按默认（阶段2 深睡 + dance）启动
4. 按电源键进入屏保，等下一个整点即可看到自动换图。**12/13 无需点**：dance 已默认开，
   「13 关」反而会导致整点不更新，仅用于诊断或恢复误改。

> `SS_RTC` / `SS_WIFI_DANCE` 也可写在 `ss_config.local`（deploy 不会覆盖它），是用户侧持久开关。
> **注意 local 优先级更高**：若曾在 local 里写过 `SS_WIFI_DANCE=0`（例如点过「13」），
> 会覆盖新的默认值 1；删掉该行或点「12」写回 1 即可恢复。

### 真机验证记录（2026-11-06，Kindle 8 / 5.16.2.1.1 + linkss）

| 时刻 | 配置 | 结果 |
|---|---|---|
| 00:00 | `SS_RTC=1`, `SS_WIFI_DANCE=0`（纯静默重连） | **失败**：整点无更新，画面滞留前一日 23:00 |
| 00:08 | 点「12」开 dance + 按电源进屏保 | 画面更新为 00:00 图（重启补刷） |
| 01:00 | `SS_RTC=1`, `SS_WIFI_DANCE=1`，**全程未碰设备** | **成功**：屏保自动刷新为 01:00 图 |

结论：RTC 唤醒链路（`readyToSuspend` 设 `rtcWakeup` → 整点唤醒 → `eips` 重绘屏保）在本固件
工作正常；唯一卡点是唤醒后的 WiFi 重连，必须由 dance 解决。

### 阶段2 验收清单（新设备自检）

1. 按电源键让设备休眠。
2. 等**下一个整点**，确认屏保自动刷新（时间戳/内容变化）。
3. 刷新前设备应是**真睡**（不像阶段1 那样周期性闪屏），只在整点"醒一下"取图刷屏。
4. 看日志确认链路：
   - `/mnt/us/dash/ss.log` — 调度与电源事件，应能看到
     `rtcWakeup` / `wakeupFromSuspend` / `wifi_restore` 相关记录
   - `/mnt/us/dash/ss_rtc.log` — 「10/11」开关动作记录

### 回退（阶段2 不生效时用「11」）

若整点不更新 / 不唤醒：

- KUAL「**11 阶段2深睡:关(回阶段1)**」→ 写 `SS_RTC=0` → 退回阶段1 兜底
  （续航 1–2 天，但每小时仍自动换图，功能不丢）。
- 若此前开过「12 WiFi dance」，可 KUAL「**13 阶段2 WiFi dance:关**」关掉兜底（纯静默重连）。

### 阶段2 的真机坑：深睡后 WiFi 断、suspended 态无法静默重连（已解决）

**00:00 实测现象**：阶段2 开启但 dance 未开时，整点没有自动换图，画面一直停在 23:00。
**根因**（经多篇文章交叉验证，非 linkss 吞事件）：
固件 **5.16.x 在 suspend 时会切断 WiFi**，且 suspended 状态下框架**拒绝任何层级的 WiFi 关联**
（`com.lab126.wifid enable` / `ensureConnection` / `wpa_cli reassociate` / `udhcpc` 全失败）。
RTC 确实唤醒了设备，但此时 WiFi 是断的 → 取不到图 → 旧画面滞留。
手动按电源键能恢复，正是因为物理按键把框架踢回 active 态，WiFi 才重新关联。

**修复**（`ss_config.sh` 的 `wifi_restore()`，调度器 / 取图脚本共用）：
- 唤醒后先静默快速试探 `SS_WIFI_SILENT_T`（默认 **15s**）：`wirelessEnable 1` + `wifid enable 1`
  + `ensureConnection` + `udhcpc` 兜底 DHCP，连上即返回。
- 静默不成 → **dance**（`SS_WIFI_DANCE=1`，本固件默认开）：`toggleSuspend` 强制 active
  约 3s 让 WiFi 连通，取图刷屏后再休眠。纯静默模式（`SS_WIFI_DANCE=0`）才改用
  `SS_WIFI_RESTORE_T`（150s）完整预算，供不启用 dance 的设备使用。
- **为什么不默认等满 150s 再 dance**：本固件静默基本连不上，每次唤醒白等两分半、
  24 次/天约多 1 小时 active，会直接拖垮周级续航。先快试 15s 再 dance 是省电关键。
- 防中途挂起：调度器在 `wakeupFromSuspend` 里先 `deferSuspend 180`，防止更新途中被 powerd
  重新挂起而漏掉下一次 `readyToSuspend`（那会导致 `rtcWakeup` 没设上、后续不再唤醒）。

### 已知边界（阶段2）

上面三个原本的真机变量（① `readyToSuspend` 事件、② `rtcWakeup` 真唤醒、
③ 唤醒瞬间 `eips` 重绘屏保）已由 **01:00 自动更新成功**全部证实，不再是未知数。

仍需留意的边界：
- **续航为估算值**：5 次/日 ≈ 8–15 天、每小时 24 次 ≈ 6–9 天（890mAh 级电池、单次唤醒约 2mAh）。
  当前 `SS_HOURS` 是每小时 24 次，若实测撑不到一周，把 `SS_HOURS` 改成 `0 6 9 12 18` 等即可。
- **失败不重试**：单次唤醒总预算 60s，取图失败就等下个整点，避免尾部耗电。
- **`ss_config.local` 优先级最高**：历史遗留的 `SS_WIFI_DANCE=0` / `SS_RTC=0` 会覆盖新默认值。
- 退回阶段1 不影响"每小时自动换图"这一核心功能。

### 关键文件（设备侧）

| 文件 | 说明 |
|---|---|
| `ss_config.sh` | 配置（含 `SS_HOURS` / `SS_RTC` / `SS_WIFI_DANCE` / `SS_WIFI_SILENT_T` 默认值与说明） |
| `ss_scheduler.sh` | 调度器，`SS_RTC` 决定走阶段1/阶段2 主循环 |
| `ss_update_once.sh` | 单次取图 + `eips` 刷屏（含 MD5 跳过重刷） |
| `ss_enable.sh` / `ss_disable.sh` | upstart 启停（拷入 tmpfs 再 exec，防持 `/mnt/us` 句柄损坏 FAT） |
| `ss_rtc.sh` / `ss_dance.sh` | KUAL「10/11」切 `SS_RTC`、「12/13」切 `SS_WIFI_DANCE`，都写 `ss_config.local` 并重启调度器 |
