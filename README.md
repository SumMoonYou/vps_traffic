# VPS流量监控脚本并通过Telegram通知

✅ 使用说明
- 下载脚本
  ```
  bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/vps_traffic/refs/heads/main/vps_vnstat_telegram.sh)" @ install
  ```
  
- 按提示输入：
 • 每月流量重置日期
 • Telegram Bot Token
 • Telegram Chat ID
 • 每日提醒时间（小时/分钟）
 • 当月总流量阈值（单位 MB，0 为不提醒）
 • 网卡名称（默认自动检测第一个非 lo 网卡）

- 安装完成后：
 • 脚本会每天按指定时间发送日报
 • 如果当月累计流量超过阈值，会发送额外提醒
 • 每月 RESET_DAY 会发送月度汇总
