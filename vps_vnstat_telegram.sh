#!/bin/bash
# VPS vnStat Telegram 流量统计安装配置脚本（带配置文件，手动+定时+月度）

CONFIG_FILE="/etc/vps_vnstat_config.conf"

echo "=============================="
echo "vnStat Telegram 流量统计一键安装脚本"
echo "=============================="

# 安装依赖
#echo "正在安装 vnStat、jq 和 bc..."
#sudo apt update
#sudo apt install -y vnstat jq curl bc

echo "正在检查系统类型..."
# 读取系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID            # ubuntu、debian、centos、fedora、rhel、alpine 等
    OS_LIKE=$ID_LIKE  # debian、rhel 等
else
    echo "无法判断系统类型！"
    exit 1
fi
echo "检测到系统: $OS (like: $OS_LIKE)"
install_debian() {
    echo "使用 apt 安装依赖..."
    sudo apt update
    sudo apt install -y vnstat jq curl bc
}
install_rhel() {
    echo "使用 yum / dnf 安装依赖..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y vnstat jq curl bc
    else
        sudo yum install -y vnstat jq curl bc
    fi
}
install_fedora() {
    echo "使用 dnf 安装依赖..."
    sudo dnf install -y vnstat jq curl bc
}
install_alpine() {
    echo "使用 apk 安装依赖..."
    sudo apk update
    sudo apk add vnstat jq curl bc
}
install_openwrt() {
    echo "使用 opkg 安装依赖..."
    opkg update
    opkg install vnstat jq curl bc
}
# 判断系统
case "$OS" in
    ubuntu|debian)
        install_debian
        ;;
    centos|rhel)
        install_rhel
        ;;
    fedora)
        install_fedora
        ;;
    alpine)
        install_alpine
        ;;
    openwrt)
        install_openwrt
        ;;
    *)
        # 有些系统 OS 识别不准确，用 ID_LIKE 兜底
        if [[ "$OS_LIKE" == *"debian"* ]]; then
            install_debian
        elif [[ "$OS_LIKE" == *"rhel"* ]]; then
            install_rhel
        else
            echo "未知系统：$OS，无法自动安装！"
            exit 1
        fi
        ;;
esac
echo "依赖安装完成！"

# 如果配置文件存在，读取变量
if [ -f "$CONFIG_FILE" ]; then
    echo "读取已有配置文件..."
    source "$CONFIG_FILE"
else
    # 用户输入配置
    read -p "请输入每月流量重置日期（1-28/30/31）: " RESET_DAY
    read -p "请输入 Telegram Bot Token: " BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " CHAT_ID
    read -p "请输入每日提醒时间（小时，0-23）: " DAILY_HOUR
    read -p "请输入每日提醒时间（分钟，0-59）: " DAILY_MIN
    # 默认网卡检测
    DEFAULT_IFACE=$(ip link show | awk -F: '$0 !~ "lo|vir|wl|docker|^[^0-9]"{print $2; exit}' | tr -d ' ')
    read -p "请输入要监控的网卡名称（默认: $DEFAULT_IFACE）: " IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    # 保存到配置文件
    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
EOF
    sudo chmod 600 "$CONFIG_FILE"
    echo "配置已保存到 $CONFIG_FILE"
fi

# 创建 vnStat Telegram 脚本
SCRIPT_PATH="/usr/local/bin/vps_vnstat_telegram.sh"
echo "生成 vnStat Telegram 脚本到 $SCRIPT_PATH ..."
sudo tee $SCRIPT_PATH >/dev/null <<EOF
#!/bin/bash
CONFIG_FILE="$CONFIG_FILE"
source "\$CONFIG_FILE"

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

# 转换单位
DAY_RX=\$(format_bytes_int \$DAY_RX_BYTES)
DAY_TX=\$(format_bytes_int \$DAY_TX_BYTES)
DAY_TOTAL=\$(format_bytes_int \$DAY_TOTAL_BYTES)

MONTH_RX_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_RX_BYTES/1024/1024/1024}")
MONTH_TX_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_TX_BYTES/1024/1024/1024}")
MONTH_TOTAL_GB=\$(awk "BEGIN {printf \"%.2f\", \$MONTH_TOTAL_BYTES/1024/1024/1024}")

# 发送 Telegram 消息函数
send_message() {
    local MSG="\$1"
    curl -s -X POST "\$TG_API" \
        -d chat_id="\$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="\$MSG" >/dev/null 2>&1
}

# 每日流量推送
MSG="📊 *VPS 流量日报*
🖥️ 主机: \$HOST_NAME
🌐 IP: \$VPS_IP
⏰ 时间: \$CUR_DATE
💾 网卡: \$IFACE
⬇️ 下载: \$DAY_RX
⬆️ 上传: \$DAY_TX
📦 当日总计: \$DAY_TOTAL
🔁 每月重置日: \$RESET_DAY 号"
send_message "\$MSG"

# 每月汇总
if [ "\$DAY_OF_MONTH" = "\$RESET_DAY" ]; then
    MONTH_MSG="📊 *VPS 月度流量汇总*
🖥️ 主机: \$HOST_NAME
🌐 IP: \$VPS_IP
📅 月份: \$CUR_MONTH
⬇️ 下载: \${MONTH_RX_GB}GB
⬆️ 上传: \${MONTH_TX_GB}GB
📦 总计: \${MONTH_TOTAL_GB}GB"
    send_message "\$MONTH_MSG"
fi
EOF

sudo chmod +x $SCRIPT_PATH

# 添加 Cron 定时任务
CRON_JOB="$DAILY_MIN $DAILY_HOUR * * * $SCRIPT_PATH >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -

echo "=============================="
echo "安装配置完成！"
echo "每日提醒已设置为 $DAILY_HOUR:$DAILY_MIN"
echo "可手动发送即时流量通知:"
echo "  sudo $SCRIPT_PATH"
echo "配置文件路径: $CONFIG_FILE"
echo "脚本路径: $SCRIPT_PATH"
echo "=============================="
