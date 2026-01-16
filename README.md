# 📊 vnStat Telegram 流量日报管理工具

一个基于 **vnStat** 的服务器流量统计脚本，支持 **Telegram 每日自动推送流量报告**，适用于 VPS / 独立服务器流量监控。

---

## ✨ 功能特性

- 📈 **昨日流量统计**（下载 / 上传 / 合计）
- 📅 **自定义流量统计周期**
- 🔄 **按月自动重置周期**
- 📊 **周期累计用量 & 百分比进度条**
- 🤖 **Telegram Bot 自动推送**
- ⏰ **Cron 定时任务**
- 🧩 **一键安装 / 修改 / 卸载**
- 🌐 **自动识别默认网卡**
- 🧮 **单位自动换算（MB / GB / TB）**

---

## 📦 依赖环境

脚本会自动检测并安装以下依赖：

- `vnstat`
- `bc`
- `curl`
- `cron / crond`

支持系统：

- ✅ Debian / Ubuntu
- ✅ CentOS 7+
- ✅ 大多数主流 Linux 发行版

---

## 🚀 安装方式

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/vps_traffic/refs/heads/main/vps_vnstat_telegram.sh)" @ install
```

## ⚙️ 配置说明

| 配置项       | 说明                   |
| ------------ | ---------------------- |
| `HOST_ALIAS` | 主机别名（TG 显示用）  |
| `TG_TOKEN`   | Telegram Bot Token     |
| `TG_CHAT_ID` | 接收消息的 Chat ID     |
| `RESET_DAY`  | 每月流量重置日（1-31） |
| `MAX_GB`     | 月流量上限（GB）       |
| `INTERFACE`  | 统计的网卡名称         |
| `RUN_TIME`   | 每日发送时间（HH:MM）  |


## 📩 Telegram 消息示例

```
📊 流量日报 (2026-01-15) | VPS-01

🏠 地址： 1.2.3.4
⬇️ 下载： 12.34 GB
⬆️ 上传： 5.67 GB
🈴 合计： 18.01 GB

📅 周期：2026-01-10 ~ 2026-02-09
🔄 重置：每月 10 号
⏳ 累计：45.32 / 100 GB
🎯 进度： 🟩🟩🟩⬜⬜⬜⬜⬜⬜⬜ 45%

🕙 2026-01-16 01:30
```



