#!/bin/bash
# install_vps_vnstat.sh
# 一键安装/卸载 VPS vnStat Telegram 流量日报脚本（修复 today 流量显示问题）
# 支持 systemd timer
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err()  { echo -e "[\e[31mERR\e[0m] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

install_dependencies() {
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
}

generate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "配置文件已存在：$CONFIG_FILE"
        return
    fi
    read -rp "请输入每月流量重置日 (1-28/29/30/31): " RESET_DAY
    read -rp "请输入 Telegram Bot Token: " BOT_TOKEN
    read -rp "请输入 Telegram Chat ID: " CHAT_ID
    read -rp "请输入每月流量总量 (GB, 0 不限制): " MONTH_LIMIT_GB
    read -rp "请输入每日提醒小时 (0-23): " DAILY_HOUR
    read -rp "请输入每日提醒分钟 (0-59): " DAILY_MIN
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

generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"

# 读取配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

RESET_DAY=${RESET_DAY:-1}
BOT_TOKEN=${BOT_TOKEN:-""}
CHAT_ID=${CHAT_ID:-""}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
DAILY_HOUR=${DAILY_HOUR:-0}
DAILY_MIN=${DAILY_MIN:-0}
IFACE=${IFACE:-eth0}
ALERT_PERCENT=${ALERT_PERCENT:-10}

TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

HOST=$(hostname)
IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "未知")
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# 字节转可读
format_bytes() {
    local b=$1
    awk -v b="$b" 'BEGIN{split("B KB MB GB TB", u, " ");i=0; while(b>=1024 && i<4){b/=1024;i++} printf "%.2f%s",b,u[i+1]}'
}

# 读取 snapshot
if [ -f "$STATE_FILE" ]; then
    SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")
    SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
else
    SNAP_BYTES=0
    SNAP_DATE=$(date +%Y-%m-%d)
    CUR_SUM=$(vnstat -i "$IFACE" --json | jq '[.interfaces[0].traffic.day[]? | (.rx + .tx)] | add // 0')
    echo "{\"last_snapshot_date\":\"$SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
fi

# ===========================
# 修复 today 流量统计
# ===========================
read DAY_RX DAY_TX DAY_TOTAL < <(
vnstat -i "$IFACE" --json | jq -r '
  .interfaces[0].traffic.day[]
  | select(
      .date.year  == (now|strftime("%Y")|tonumber) and
      .date.month == (now|strftime("%m")|tonumber) and
      .date.day   == (now|strftime("%d")|tonumber)
    )
  | "\(.rx) \(.tx) \(.rx + .tx)"
'
)

DAY_RX=${DAY_RX:-0}
DAY_TX=${DAY_TX:-0}
DAY_TOTAL=${DAY_TOTAL:-0}

# 本周期使用
CUR_SUM=$(vnstat -i "$IFACE" --json | jq '[.interfaces[0].traffic.day[]? | (.rx + .tx)] | add // 0')
USED_BYTES=$((CUR_SUM - SNAP_BYTES))
[ $USED_BYTES -lt 0 ] && USED_BYTES=0
MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
[ "$MONTH_LIMIT_BYTES" -le 0 ] && REMAIN_BYTES=0 || REMAIN_BYTES=$((MONTH_LIMIT_BYTES - USED_BYTES))
[ $REMAIN_BYTES -lt 0 ] && REMAIN_BYTES=0

# 进度条
PERCENT=0
[ "$MONTH_LIMIT_BYTES" -gt 0 ] && PERCENT=$((USED_BYTES*100/MONTH_LIMIT_BYTES))
BAR_LEN=10
FILLED=$((PERCENT*BAR_LEN/100))
BAR=""
for ((i=0;i<BAR_LEN;i++)); do
    if [ $i -lt $FILLED ]; then
        if [ $PERCENT -lt 70 ]; then BAR+="🟩"; elif [ $PERCENT -lt 90 ]; then BAR+="🟨"; else BAR+="🟥"; fi
    else
        BAR+="⬜️"
    fi
done

# 构建消息
MSG="📊 VPS 流量日报


🖥️ 主机: $HOST   
🌐 IP: $IP   
💾 网卡: $IFACE
⏰ 时间: $(date '+%Y-%m-%d %H:%M:%S')

🔹 今日流量
⬇️ 下载: $(format_bytes $DAY_RX)   ⬆️ 上传: $(format_bytes $DAY_TX)   📦 总计: $(format_bytes $DAY_TOTAL)

🔸 本周期流量 (自 $SNAP_DATE 起)
📌 已用: $(format_bytes $USED_BYTES)   剩余: $(format_bytes $REMAIN_BYTES) / 总量: $(format_bytes $MONTH_LIMIT_BYTES)
📊 进度: $BAR $PERCENT%"

# 流量告警
if [ "$MONTH_LIMIT_BYTES" -gt 0 ] && [ "$ALERT_PERCENT" -gt 0 ]; then
    REMAIN_PERCENT=$((REMAIN_BYTES*100/MONTH_LIMIT_BYTES))
    if [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
        MSG="$MSG
⚠️ 流量告警：剩余 $REMAIN_PERCENT% (≤ $ALERT_PERCENT%)"
    fi
fi

curl -s -X POST "$TG_API" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MSG" >/dev/null 2>&1
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本生成完成：$SCRIPT_FILE"
}

generate_systemd() {
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
OnCalendar=*-*-* ${DAILY_HOUR:-00}:${DAILY_MIN:-00}:00
Persistent=true
Unit=vps_vnstat_telegram.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
    info "systemd timer 已启用。"
}

uninstall_all() {
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload
    info "卸载完成。"
}

main() {
    echo "选择操作："
    echo "1) 安装"
    echo "2) 卸载"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            source "$CONFIG_FILE"
            generate_systemd
            ;;
        2)
            uninstall_all
            ;;
        *)
            echo "无效选项"
            ;;
    esac
}

main
