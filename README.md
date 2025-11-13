# VPS流量监控脚本并通过Telegram通知

- 一、安装vnStant

  ```
  sudo apt update
  sudo apt install vnstat jq -y
  ```

- 下载脚本

  ```
  wget -N --no-check-certificate "https://raw.githubusercontent.com/SumMoonYou/vps_traffic/refs/heads/main/vps_traffic.sh" && chmod +x vps_traffic.sh && ./vps_traffic.sh
  ```

- 修改配置

  ```
  BOT_TOKEN="" //你的BotToken
  CHAT_ID="" //你的ChatID
  IFACE="eth0" //监听网卡
  RESET_DAY=1 //流量重置日期
  ```

  

- 设置定时任务

  ```
  sudo crontab -e
  
  59 23 * * * /root/vps_traffic.sh >/dev/null 2>&1
  ```
