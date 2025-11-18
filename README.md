# VPS vnStat Telegram 流量统计脚本

📊 一键安装、每日推送 VPS 流量统计到 Telegram，包括当日流量、本周期已用/剩余流量，以及每月汇总。  
支持 **Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine/OpenWRT** 系统（需 root 权限）。

---

## 功能特点

- 自动检测系统类型并安装依赖：`vnstat`、`jq`、`curl`、`bc`  
- 配置文件保存用户设置，支持修改  
- 每日发送 Telegram 流量日报（下载、上传、总计）  
- 显示本周期已用流量、剩余流量、总量、进度条和状态  
- 每月在重置日发送周期汇总  
- 支持 systemd timer 定时任务，也可回退到 crontab  
- 可设置流量告警阈值，当剩余流量低于阈值时 Telegram 提示

---

## 安装使用

### 1. 下载并运行安装脚本

```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/vps_traffic/refs/heads/main/vps_vnstat_telegram.sh)" @ install
```

> 安装过程中会提示输入配置：
>
> - 每月流量重置日（1-28/29/30/31）
> - Telegram Bot Token
> - Telegram Chat ID
> - 每月流量总量（GB，0 表示无限制）
> - 每日推送时间（小时和分钟）
> - 监控网卡名称（默认自动检测）
> - 剩余流量告警阈值百分比（默认 10%）

安装完成后：

- 配置文件路径：`/etc/vps_vnstat_config.conf`
- 主脚本路径：`/usr/local/bin/vps_vnstat_telegram.sh`
- 状态文件路径：`/var/lib/vps_vnstat_telegram/state.json`
- systemd timer 名称：`vps_vnstat_telegram.timer`

### 2. 查看 timer 状态

```
# 查看所有 systemd timer
systemctl list-timers --all

# 查看本脚本 timer 状态
systemctl status vps_vnstat_telegram.timer

# 查看定时执行日志
journalctl -u vps_vnstat_telegram.service -e
```

### 3. 手动发送即时流量报告

```
sudo /usr/local/bin/vps_vnstat_telegram.sh
```

## 配置文件说明

配置文件路径：`/etc/vps_vnstat_config.conf`

示例内容：

```
RESET_DAY=1
BOT_TOKEN=""
CHAT_ID="-"
MONTH_LIMIT_GB=500
DAILY_HOUR=9
DAILY_MIN=0
IFACE="eth0"
ALERT_PERCENT=10
```

字段说明：

| 参数           | 说明                                |
| -------------- | ----------------------------------- |
| RESET_DAY      | 每月流量重置日（1-31）              |
| BOT_TOKEN      | Telegram Bot Token                  |
| CHAT_ID        | Telegram Chat ID                    |
| MONTH_LIMIT_GB | 每月流量总量（GB），0 表示不限制    |
| DAILY_HOUR     | 每日发送时间（小时，0-23）          |
| DAILY_MIN      | 每日发送时间（分钟，0-59）          |
| IFACE          | 要监控的网卡名称                    |
| ALERT_PERCENT  | 剩余流量告警阈值（%），0 表示不告警 |

> 可直接编辑该文件修改配置，保存后 timer 会按新配置执行。

## 流量报告样式示例

### 每日流量日报

```
📊 VPS 流量日报
🖥️ 主机: my-vps   🌐 IP: 1.2.3.4
💾 网卡: eth0   ⏰ 2025-11-18 09:00:00

🔹 今日流量
⬇️ 下载: 1.23GB   ⬆️ 上传: 0.45GB   📦 总计: 1.68GB

🔸 本周期流量 (2025-11-01 → 2025-11-18)
📌 已用: 25.50GB
📌 剩余: 724.50GB / 总量 750 GB
📊 进度: 🟩🟩🟩⬜️⬜️⬜️⬜️⬜️⬜️⬜️ 3%   ⚡️ 流量状态: ✅
```

### 每月流量周期汇总（在重置日发送）

```
📊 VPS 流量周期汇总
🖥️ 主机: my-vps
🌐 IP: 1.2.3.4

📅 周期: 2025-11-01 → 2025-11-30
📦 本周期使用: 750GB
📦 本周期剩余: 0GB / 总量 750 GB
📊 进度: 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 100%   ⚡️ 流量状态: ⚠️
```

## 常见问题

1. **脚本报错 `配置文件缺失`**

   - 说明配置文件 `/etc/vps_vnstat_config.conf` 不存在或被删除，请重新运行安装脚本生成配置。

2. **主机名或 IP 无法显示**

   - 脚本会自动获取公网 IP，如 VPS 防火墙限制访问外网，请确保 `curl` 可以访问 `https://api.ipify.org`。

3. **使用 systemd timer 不触发**

   - 检查 timer 状态：

     ```
     systemctl list-timers --all
     systemctl status vps_vnstat_telegram.timer
     ```

     

   - 手动运行 service 测试：

     ```
     systemctl start vps_vnstat_telegram.service
     ```

## 卸载

如果不再使用，可以删除脚本、配置和状态文件，并禁用 timer：

```
sudo systemctl disable --now vps_vnstat_telegram.timer
sudo rm -f /usr/local/bin/vps_vnstat_telegram.sh
sudo rm -f /etc/vps_vnstat_config.conf
sudo rm -rf /var/lib/vps_vnstat_telegram
```
