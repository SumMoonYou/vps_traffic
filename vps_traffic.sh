#!/bin/bash
# VPS vnStat Telegram 流量统计安装配置脚本（含总流量GB提醒）

echo "=============================="
echo "vnStat Telegram 流量统计一键安装脚本"
echo "=============================="

# 安装依赖
echo "正在安装 vnStat 和 jq..."
sudo apt update
sudo apt install -y vnstat jq curl bc

# 用户输入配置
read -p "请输入每月流量重置日期（1-28/30/31）: " RESET_DAY
read -p "请输入 Telegram Bot Token: " BOT_TOKEN
read -p "请输入 Telegram Chat ID: " CHAT_ID
read -p "请输入每日提醒时间（小时，0-23）: " DAILY_HOUR
read -p "请输入每日提醒时间（分钟，0-59）: " DAILY_MIN
read -p "请输入当月总流量阈值（单位 GB, 超过会提醒，0为不提醒）: " TOTAL_THRESHOLD_GB

# 默认网卡检测
DEFAULT_IFACE=$(ip link show | awk -F: '$0 !~ "lo|vir|wl|docker|^[^0-9]"{print $2; exit}' | tr -d ' ')
read -p "请输入要监控的网卡名称（默认: $DEFAULT_IFACE）: " IFACE
IFACE=${IFACE:-$DEFAULT_IFACE}

# 创建脚本
SCRIPT_PATH="/usr/local/bin/vps_vnstat_telegram.sh"
echo "生成 vnStat Telegram 脚本到 $SCRIPT_PATH ..."
sudo tee $SCRIPT_PATH >/dev/null <<EOF
#!/bin/bash
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
RESET_DAY=$RESET_DAY
IFACE="$IFACE"
TOTAL_THRESHOLD_GB=$TOTAL_THRESHOLD_GB
TG_API="https://api.telegram.org/bot\$BOT_TOKEN/sendMessage"

HOST_NAME=\$(hostname)
VPS_IP=\$(curl -s https://api.ipify.org 2>/dev/null)
[ -z "\$VPS_IP" ] && VPS_IP="无法获取"

CUR_DATE=\$(date +"%Y-%m-%d %H:%M:%S")
CUR_MONTH=\$(date +%Y)
DAY_OF_MONTH=\$(date +%d)

format_bytes_int() {
    local bytes=\$1
    [ -z "\$bytes" ] && bytes=0
    if ! [[ "\$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi
    local unit=("B" "KB" "MB" "GB" "TB")
    local i=0
    while [ \$bytes -ge 1024 ] && [ \$i -lt 4 ]; do
        bytes=\$((bytes / 1024))
        i=\$((i + 1))
    done
    echo "\${bytes}\${unit[\$i]}"
}

# 日流量
DAY_RX_BYTES=\$(vnstat -i \$IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].rx // 0')
DAY_TX_BYTES=\$(vnstat -i \$IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].tx // 0')
DAY_TOTAL_BYTES=\$((DAY_RX_BYTES + DAY_TX_BYTES))

# 月流量
MONTH_RX_BYTES=\$(vnstat -i \$IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.month[-1].rx // 0')
MONTH_TX_BYTES=\$(vnstat -i \$IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.month[-1].tx // 0')
MONTH_TOTAL_BYTES=\$((MONTH_RX_BYTES + MONTH_TX_BYTES))

DAY_RX=\$(format_bytes_int \$DAY_RX_BYTES)
DAY_TX=\$(format_bytes_int \$DAY_TX_BYTES)
DAY_TOTAL=\$(format_bytes_int \$DAY_TOTAL_BYTES)

MONTH_RX_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_RX_BYTES/1024/1024/1024}")
MONTH_TX_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_TX_BYTES/1024/1024/1024}")
MONTH_TOTAL_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_TOTAL_BYTES/1024/1024/1024}")

# 每日流量推送
MSG="📊 *VPS 流量日报*
🖥 主机: \$HOST_NAME
🌐 IP: \$VPS_IP
⏰ 时间: \$CUR_DATE
💾 网卡: \$IFACE
⬇️ 下载: \$DAY_RX
⬆️ 上传: \$DAY_TX
📦 当日总计: \$DAY_TOTAL
🔁 每月重置日: \$RESET_DAY 号"

curl -s -X POST "\$TG_API" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$MSG" >/dev/null 2>&1

# 当月总流量GB阈值提醒
if [ \$TOTAL_THRESHOLD_GB -gt 0 ]; then
    if (( \$(echo "\$MONTH_TOTAL_GB >= \$TOTAL_THRESHOLD_GB" | bc -l) )); then
        ALERT_MSG="⚠️ *VPS 总流量提醒*\n🖥 主机: \$HOST_NAME\n🌐 IP: \$VPS_IP\n📅 月累计流量: \${MONTH_TOTAL_GB}GB (已超过阈值 ${TOTAL_THRESHOLD_GB}GB)"
        curl -s -X POST "\$TG_API" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$ALERT_MSG" >/dev/null 2>&1
    fi
fi

# 每月汇总
if [ "\$DAY_OF_MONTH" = "\$RESET_DAY" ]; then
    MONTH_MSG="📊 *VPS 月度流量汇总*
🖥 主机: \$HOST_NAME
🌐 IP: \$VPS_IP
📅 月份: \$CUR_MONTH
⬇️ 下载: \${MONTH_RX_GB}GB
⬆️ 上传: \${MONTH_TX_GB}GB
📦 总计: \${MONTH_TOTAL_GB}GB"
    curl -s -X POST "\$TG_API" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$MONTH_MSG" >/dev/null 2>&1
fi
EOF

sudo chmod +x $SCRIPT_PATH

# 添加 Cron 定时任务
CRON_JOB="$DAILY_MIN $DAILY_HOUR * * * $SCRIPT_PATH >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -

echo "=============================="
echo "安装配置完成！"
echo "每日提醒已设置为 $DAILY_HOUR:$DAILY_MIN"
echo "当月总流量阈值: $TOTAL_THRESHOLD_GB GB"
echo "脚本路径: $SCRIPT_PATH"
echo "=============================="
