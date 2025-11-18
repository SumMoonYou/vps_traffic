#!/bin/bash
# install_vps_vnstat_telegram.sh
# 一键安装 vnStat + Telegram 流量统计脚本 + 自动配置每日/周期提醒
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SCRIPT_PATH="/usr/local/bin/vps_vnstat_telegram.sh"
SERVICE_NAME="vps_vnstat_telegram.service"
TIMER_NAME="vps_vnstat_telegram.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

# 彩色输出
info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err()  { echo -e "[\e[31mERR\e[0m] $*"; }

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户或使用 sudo 运行此脚本。"
    exit 1
fi

# ---------------------------
# 系统检测及依赖安装
# ---------------------------
install_debian() { apt update -y && apt install -y vnstat jq curl bc; }
install_rhel() { if command -v dnf &>/dev/null; then dnf install -y vnstat jq curl bc; else yum install -y epel-release -y && yum install -y vnstat jq curl bc; fi; }
install_fedora() { dnf install -y vnstat jq curl bc; }
install_alpine() { apk update && apk add vnstat jq curl bc; }
install_openwrt() { opkg update && opkg install vnstat jq curl bc; }

detect_and_install() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_LIKE=${ID_LIKE:-}
    else
        err "无法识别系统类型，请手动安装 vnstat jq curl bc。"
        exit 1
    fi
    info "检测系统: $OS (like: $OS_LIKE)"
    case "$OS" in
        ubuntu|debian) install_debian ;;
        centos|rhel) install_rhel ;;
        fedora) install_fedora ;;
        alpine) install_alpine ;;
        openwrt) install_openwrt ;;
        *) 
            if [[ "$OS_LIKE" == *"debian"* ]]; then install_debian
            elif [[ "$OS_LIKE" == *"rhel"* ]]; then install_rhel
            else warn "未知系统：$OS，尝试使用 apt 安装"; install_debian || warn "请手动安装依赖"
            fi
            ;;
    esac
}

# ---------------------------
# 配置文件
# ---------------------------
create_or_read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "检测到已有配置 $CONFIG_FILE"
        source "$CONFIG_FILE"
        : "${RESET_DAY:?配置文件缺少 RESET_DAY}"
        : "${BOT_TOKEN:?配置文件缺少 BOT_TOKEN}"
        : "${CHAT_ID:?配置文件缺少 CHAT_ID}"
        : "${MONTH_LIMIT_GB:=0}"
        : "${DAILY_HOUR:=8}"
        : "${DAILY_MIN:=0}"
        : "${IFACE:='eth0'}"
        : "${ALERT_PERCENT:=10}"
    else
        info "创建新配置..."
        DEFAULT_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | egrep -v "lo|vir|wl|docker|veth" | head -n1 || true)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE="eth0"
        read -rp "每月流量重置日(1-31): " RESET_DAY
        read -rp "Telegram Bot Token: " BOT_TOKEN
        read -rp "Telegram Chat ID: " CHAT_ID
        read -rp "每月流量总量(GB,0表示不限制): " MONTH_LIMIT_GB
        read -rp "每日提醒时间小时(0-23): " DAILY_HOUR
        read -rp "每日提醒时间分钟(0-59): " DAILY_MIN
        read -rp "要监控的网卡名称(默认 $DEFAULT_IFACE): " IFACE
        IFACE=${IFACE:-$DEFAULT_IFACE}
        read -rp "剩余流量告警百分比(默认10,0表示不告警): " ALERT_PERCENT
        ALERT_PERCENT=${ALERT_PERCENT:-10}
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
        info "配置已保存到 $CONFIG_FILE"
    fi
}

# ---------------------------
# 生成主脚本
# ---------------------------
generate_main_script() {
info "生成主脚本 $SCRIPT_PATH ..."
cat > "$SCRIPT_PATH" <<'EOSCRIPT'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
source "$CONFIG_FILE"

# 默认值
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}
RESET_DAY=${RESET_DAY:-1}
IFACE=${IFACE:-eth0}

TG_API_BASE="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
HOST_NAME=$(hostname 2>/dev/null || echo "未知主机")
VPS_IP=$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo "")
[ -z "$VPS_IP" ] && VPS_IP="无法获取"

escape_md() {
    local s="$1"
    s="${s//\*/\\*}"
    s="${s//_/\\_}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    echo "$s"
}
HOST_ESC=$(escape_md "$HOST_NAME")
IFACE_ESC=$(escape_md "$IFACE")
IP_ESC="$VPS_IP"

format_bytes() {
    local bytes="$1"
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then bytes=0; fi
    awk -v b="$bytes" 'BEGIN{
        split("B KB MB GB TB", u, " ");
        i=0; while(b>=1024 && i<4){ b=b/1024; i++; }
        if(i==0){ printf "%d%s", int(b+0.5), u[i+1]; } else { printf "%.2f%s", b, u[i+1]; }
    }'
}

get_vnstat_cumulative_days_bytes() {
    local iface="$1"
    echo $(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | ((.rx //0)+(.tx //0))] | add //0' 2>/dev/null || echo "0")
}

get_vnstat_today_bytes() {
    local iface="$1"
    local rx tx total
    rx=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | select(.date.day == (now|strftime("%d")|tonumber)) | .rx] | first // empty' 2>/dev/null || echo "")
    tx=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | select(.date.day == (now|strftime("%d")|tonumber)) | .tx] | first // empty' 2>/dev/null || echo "")
    if ! [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
        rx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].rx //0' 2>/dev/null || echo "0")
        tx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].tx //0' 2>/dev/null || echo "0")
    fi
    rx=${rx:-0}; tx=${tx:-0}
    total=$((rx+tx))
    echo "$rx $tx $total"
}

init_state_if_missing() {
    [ ! -d "$STATE_DIR" ] && mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    if [ ! -f "$STATE_FILE" ]; then
        CUR_SUM=$(get_vnstat_cumulative_days_bytes "$IFACE")
        now_date=$(date +%Y-%m-%d)
        cat > "$STATE_FILE" <<EOF
{
  "last_snapshot_date": "$now_date",
  "snapshot_bytes": $CUR_SUM
}
EOF
        chmod 600 "$STATE_FILE"
    fi
}

read_snapshot() {
    if [ -f "$STATE_FILE" ]; then
        SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE" 2>/dev/null || echo "")
        SNAP_BYTES=$(jq -r '.snapshot_bytes //0' "$STATE_FILE" 2>/dev/null || echo "0")
    else
        SNAP_DATE=""; SNAP_BYTES=0
    fi
}

write_snapshot() {
    local new_bytes="$1"
    local new_date=$(date +%Y-%m-%d)
    cat > "$STATE_FILE" <<EOF
{
  "last_snapshot_date": "$new_date",
  "snapshot_bytes": $new_bytes
}
EOF
    chmod 600 "$STATE_FILE"
}

send_message() {
    local text="$1"
    curl -s -X POST "${TG_API_BASE}" --max-time 10 \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

generate_progress_bar() {
    local used_bytes=$1 total_bytes=$2 length=20 percent=0
    [ "$total_bytes" -gt 0 ] && percent=$((used_bytes*100/total_bytes))
    local filled=$(( percent*length/100 ))
    local empty=$(( length - filled ))
    local bar=""
    for ((i=0;i<filled;i++)); do bar+="🟩"; done
    for ((i=0;i<empty;i++)); do bar+="⬜️"; done
    echo "$bar $percent%"
}

flow_status_icon() {
    local pct=$1
    if [ "$pct" -ge 50 ]; then echo "✅"
    elif [ "$pct" -ge 20 ]; then echo "⚡️"
    else echo "⚠️"
    fi
}

main() {
    init_state_if_missing
    read_snapshot
    read DAY_RX DAY_TX DAY_TOTAL < <(get_vnstat_today_bytes "$IFACE")
    CUR_SUM=$(get_vnstat_cumulative_days_bytes "$IFACE")
    USED_BYTES=$((CUR_SUM - SNAP_BYTES)); [ "$USED_BYTES" -lt 0 ] && USED_BYTES=0
    MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf("%.0f", g*1024*1024*1024)}')
    REMAIN_BYTES=$(( MONTH_LIMIT_BYTES - USED_BYTES )); [ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0

    DAY_RX_H=$(format_bytes "$DAY_RX")
    DAY_TX_H=$(format_bytes "$DAY_TX")
    DAY_TOTAL_H=$(format_bytes "$DAY_TOTAL")
    USED_H=$(format_bytes "$USED_BYTES")
    REMAIN_H=$(format_bytes "$REMAIN_BYTES")
    LIMIT_H=$(format_bytes "$MONTH_LIMIT_BYTES")

    PROGRESS_BAR=$(generate_progress_bar "$USED_BYTES" "$MONTH_LIMIT_BYTES")
    PCT_REMAIN=$(( REMAIN_BYTES*100/MONTH_LIMIT_BYTES ))
    STATUS_ICON=$(flow_status_icon "$PCT_REMAIN")
    CUR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
    SNAP_DATE_ESC=$(escape_md "${SNAP_DATE:-起始}")

    # 每日流量消息
    MSG="📊 VPS 流量日报

🖥️ 主机: ${HOST_ESC}
🌐 IP: ${IP_ESC}
💾 网卡: ${IFACE_ESC}    ⏰ ${CUR_DATE}

🔹 今日流量
⬇️ 下载: ${DAY_RX_H}    ⬆️ 上传: ${DAY_TX_H}    📦 总计: ${DAY_TOTAL_H}

🔸 本周期流量 (${SNAP_DATE_ESC} → $(date +%Y-%m-%d))
📌 已用: ${USED_H}    剩余: ${REMAIN_H} / 总量 ${LIMIT_H}
📊 进度: ${PROGRESS_BAR}    ⚡️ 流量状态: ${STATUS_ICON}
"
    send_message "$MSG"

    TODAY_DAY=$(date +%d | sed 's/^0*//')
    if [ "$TODAY_DAY" -eq "$RESET_DAY" ]; then
        PERIOD_MSG="📊 VPS 流量周期汇总

🖥️ 主机: ${HOST_ESC}
🌐 IP: ${IP_ESC}
💾 网卡: ${IFACE_ESC}

📦 本周期使用: ${USED_H}
📦 本周期剩余: ${REMAIN_H} / 总量 ${LIMIT_H}
📊 进度: ${PROGRESS_BAR}    ⚡️ 流量状态: ${STATUS_ICON}
"
        send_message "$PERIOD_MSG"
        write_snapshot "$CUR_SUM"
    fi
}

main "$@"
EOSCRIPT

chmod 750 "$SCRIPT_PATH"
info "主脚本已生成并赋予执行权限。"
}

# ---------------------------
# systemd 或 crontab
# ---------------------------
generate_systemd_unit() {
    source "$CONFIG_FILE"
    H=$(printf "%02d" "$DAILY_HOUR")
    M=$(printf "%02d" "$DAILY_MIN")
    ONCAL="*-*-* ${H}:${M}:00"

    info "生成 systemd service 和 timer，每日 $H:$M 运行..."
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=VPS vnStat Telegram daily report
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
Nice=5
StandardOutput=null
StandardError=journal
EOF

    cat > "$TIMER_PATH" <<EOF
[Unit]
Description=Daily timer for vps_vnstat_telegram

[Timer]
OnCalendar=$ONCAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$(basename "$TIMER_PATH")" || true
    systemctl start "$(basename "$TIMER_PATH")" || true
    info "systemd timer 已启用。"
}

main_install() {
    detect_and_install
    create_or_read_config
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    generate_main_script
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
        generate_systemd_unit
    else
        warn "systemd 不可用，使用 crontab 作为回退。"
        source "$CONFIG_FILE"
        CRON_TAG="# VPS_VNSTAT_TELEGRAM"
        CRON_JOB="${DAILY_MIN} ${DAILY_HOUR} * * * ${SCRIPT_PATH} >/dev/null 2>&1 ${CRON_TAG}"
        (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true; echo "$CRON_JOB") | crontab -
    fi
    info "安装完成！手动运行: sudo $SCRIPT_PATH"
}

main_install
