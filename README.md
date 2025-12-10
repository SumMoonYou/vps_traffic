# 📊 VPS vnStat Telegram 流量日报脚本

### 自动统计 VPS 流量并每日发送 Telegram 报告 | 支持月流量限制、智能快照、彩色进度条

**版本：v1.3.5**

本脚本基于 **vnStat** 生成 VPS 网卡流量报表，并通过 **Telegram Bot** 自动发送每日流量日报。
 支持多系统、自动安装依赖、月度流量快照、剩余流量报警、手动查询指定日期等功能。

------

## ✨ 功能特性

### ✔ 自动每日流量日报推送

- 昨日下载 / 上传 / 总流量
- 当前周期（按月重置日）已用、剩余和总流量
- 自动换算流量单位 (B / KB / MB / GB / TB)

### ✔ 智能月度快照

- 在 `/var/lib/vps_vnstat_telegram/state.json` 保存月度基线
- 支持任意重置日（默认 1 号）

### ✔ 漂亮 Telegram 报表

- 带 emoji 图标
- 彩色进度条（🟩🟨🟥）
- 流量告警（默认剩余 ≤10% 触发）

### ✔ 强大的安装脚本

- 自动检测系统：Debian / Ubuntu / CentOS / Rocky / Alpine
- 自动安装 vnstat、curl、jq、bc 等依赖
- 自动生成 systemd 定时任务
- 支持升级脚本、卸载脚本

### ✔ 支持手动查询任意日期

```
/usr/local/bin/vps_vnstat_telegram.sh 2025-01-15
```

------

## 📦 安装方式

```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/vps_traffic/refs/heads/main/vps_vnstat_telegram.sh)" @ install
```

------

## 📁 文件结构

| 文件路径                                          | 用途         |
| ------------------------------------------------- | ------------ |
| `/usr/local/bin/vps_vnstat_telegram.sh`           | 主脚本       |
| `/etc/vps_vnstat_config.conf`                     | 配置文件     |
| `/var/lib/vps_vnstat_telegram/state.json`         | 月度快照     |
| `/etc/systemd/system/vps_vnstat_telegram.service` | systemd 服务 |
| `/etc/systemd/system/vps_vnstat_telegram.timer`   | 定时任务     |

------

## ⚙ 配置说明（安装脚本自动生成）

安装时会自动提示输入：

| 配置项                     | 说明                         |
| -------------------------- | ---------------------------- |
| `RESET_DAY`                | 每月流量重置日               |
| `BOT_TOKEN`                | Telegram Bot Token           |
| `CHAT_ID`                  | 你的 Telegram Chat ID        |
| `MONTH_LIMIT_GB`           | 每月总流量上限（0 = 不限制） |
| `DAILY_HOUR` / `DAILY_MIN` | 每日报告时间                 |
| `IFACE`                    | 监控的网卡名称（自动识别）   |
| `ALERT_PERCENT`            | 剩余流量百分比报警           |
| `HOSTNAME_CUSTOM`          | 手动设置主机名               |

------

## 📅 systemd 定时任务

自动安装的定时任务：

```
OnCalendar=*-*-* HH:MM:00
```

查看状态：

```
systemctl status vps_vnstat_telegram.timer
```

立即运行一次：

```
systemctl start vps_vnstat_telegram.service
```

------

## 🔧 升级脚本

```
bash install_vps_vnstat.sh
```

选择：

```
2) 升级
```

------

## 🗑 卸载脚本

```
bash install_vps_vnstat.sh
```

选择：

```
3) 卸载
```

------

## 📤 示例消息预览 (Telegram)

```
📊 VPS 流量日报

🖥 主机： MyServer
🌐 地址： 1.2.3.4
💾 网卡： eth0
⏰ 时间： 2025-01-20 00:30:00

📆 昨日流量 (2025-01-19)
⬇️ 下载： 3.52GB
⬆️ 上传： 1.17GB
↕️ 总计： 4.69GB

📅 本周期流量 (自 2025-01-01 起)
⏳ 已用： 28.51GB
⏳ 剩余： 71.49GB
⌛ 总量： 100.00GB

🔃 重置： 1 号
🎯 进度： 🟩🟩🟩🟩⬜️⬜️⬜️⬜️⬜️⬜️ 28%

⚠️ 流量告警：剩余 10% (≤ 10%)
```

------

## ⭐ 支持的系统

- Debian 9/10/11/12+
- Ubuntu 18.04/20.04/22.04+
- CentOS 7/8
- Rocky / Alma / RHEL 系
- Alpine Linux

------

## 📝 许可证

MIT License
