#!/bin/bash
# vps_vnstat_telegram.sh
# VPS vnStat Telegram 流量日报脚本（安装、升级、卸载）

set -euo pipefail
IFS=$'\n\t'

# 配置文件路径和脚本路径
CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"
BACKUP_DIR="/var/backups/vps_vnstat_telegram"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

# 安装依赖
install_dependencies() {
    info "开始安装依赖: vnstat, jq, curl, bc..."
    if [ -f /etc/debian_version ]; then
        apt update -y
        apt install -y vnstat jq curl bc
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache vnstat jq curl bc
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        if command -v dnf &>/dev/null; then
            dnf install -y vnstat jq curl bc
        else
            yum install -y epel-release
            yum install -y vnstat jq curl bc
        fi
    else
        warn "未识别系统，请确保已安装 vnstat jq curl bc"
    fi
    info "依赖安装完成。"
}

# 生成配置
generate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "配置文件已存在：$CONFIG_FILE，跳过配置生成。"
        return
    fi
    info "开始配置脚本参数..."
    read -rp "请输入每月流量重置日 (1-31, 默认1): " RESET_DAY
    RESET_DAY=${RESET_DAY:-1}
    read -rp "请输入 Telegram Bot Token: " BOT_TOKEN
    read -rp "请输入 Telegram Chat ID: " CHAT_ID
    read -rp "请输入每月流量总量 (GB, 0 不限制, 默认0): " MONTH_LIMIT_GB
    MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}

    read -rp "请输入每日提醒小时 (0-23, 建议02或03, 默认0): " DAILY_HOUR
    DAILY_HOUR=${DAILY_HOUR:-0}

    read -rp "请输入每日提醒分钟 (0-59, 默认30): " DAILY_MIN
    DAILY_MIN=${DAILY_MIN:-30}

    DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "请输入监控网卡 (默认 $DEFAULT_IFACE): " IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    read -rp "请输入流量告警阈值百分比 (默认10): " ALERT_PERCENT
    ALERT_PERCENT=${ALERT_PERCENT:-10}

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$CONFIG_FILE" <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
ALERT_PERCENT=$ALERT_PERCENT
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已保存：$CONFIG_FILE"
}

# 生成主脚本
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
DEBUG_LOG="/tmp/vps_vnstat_debug.log"

debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$DEBUG_LOG"
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

get_vnstat_json() {
    vnstat -i "$IFACE" --json 2>/dev/null || echo '{}'
}

VNSTAT_JSON=$(get_vnstat_json)

VNSTAT_VERSION=$(vnstat --version | head -n1 | awk '{print $2}' | cut -d'.' -f1)

if [ "$VNSTAT_VERSION" -ge 2 ]; then
    KIB_TO_BYTES=1
else
    KIB_TO_BYTES=1024
fi

TRAFFIC_PATH="day"

TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')

IFACE=${IFACE:-eth0}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}

TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
HOST=$(hostname)
IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "未知")

format_bytes() {
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{split("B KB MB GB TB", u, " ");i=0; while(b>=1024 && i<4){b/=1024;i++} printf "%.2f%s",b,u[i+1]}'
}

VNSTAT_JSON=$(get_vnstat_json)

DAY_VALUES=$(echo "$VNSTAT_JSON" | jq -r \
  --argjson y "$(date -d "$TARGET_DATE_STR" '+%Y')" \
  --argjson m "$(date -d "$TARGET_DATE_STR" '+%m')" \
  --argjson d "$(date -d "$TARGET_DATE_STR" '+%d')" \
  --arg path "$TRAFFIC_PATH" '
    (.interfaces[0].traffic[$path] // [])
  | map(select(.date.year == $y
               and .date.month == $m
               and .date.day == $d))
  | if length>0 then
      "\(.[-1].rx // 0) \(.[-1].tx // 0)"
    else "0 0" end
')

IFS=' ' read -r DAY_RX_UNIT DAY_TX_UNIT <<< "$DAY_VALUES"
DAY_RX=$(echo "$DAY_RX_UNIT * $KIB_TO_BYTES" | bc)
DAY_TX=$(echo "$DAY_TX_UNIT * $KIB_TO_BYTES" | bc)
DAY_TOTAL=$(echo "$DAY_RX + $DAY_TX" | bc)

MSG="📊 VPS 流量日报

🖥 主机： $HOST
🌐 地址： $IP
💾 网卡： $IFACE
⏰ 时间： $(date '+%Y-%m-%d %H:%M:%S')

📆 昨日流量 ($TARGET_DATE_STR)
⬇️ 下载： $(format_bytes $DAY_RX)
⬆️ 上传： $(format_bytes $DAY_TX)
↕️ 总计： $(format_bytes $DAY_TOTAL)"

curl -s -X POST "$TG_API" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$MSG" >/dev/null 2>&1
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新。"
}

# 生成 systemd 服务和定时器
generate_systemd() {
    source "$CONFIG_FILE" || { err "无法加载配置，无法生成 systemd 文件"; exit 1; }

    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS vnStat Telegram Daily Report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily timer for VPS vnStat Telegram Report

[Timer]
OnCalendar=*-*-* ${DAILY_HOUR}:${DAILY_MIN}:00
Persistent=true
Unit=vps_vnstat_telegram.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
    info "systemd timer 已启用，配置为 ${DAILY_HOUR}:${DAILY_MIN} 运行。"
}

# 升级功能
upgrade_script
