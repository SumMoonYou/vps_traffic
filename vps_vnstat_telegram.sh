#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报 + 每小时上传脚本 v1.4.2
set -euo pipefail
IFS=$'\n\t'

VERSION="v1.4.2"
CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
UPLOAD_SCRIPT_FILE="/usr/local/bin/vps_vnstat_upload.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"
UPLOAD_SERVICE_FILE="/etc/systemd/system/vps_vnstat_upload.service"
UPLOAD_TIMER_FILE="/etc/systemd/system/vps_vnstat_upload.timer"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

echo -e "VPS vnStat Telegram 流量日报 + 上传脚本 $VERSION\n"

if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

# ---------------- 安装依赖 ----------------
install_dependencies() {
    info "开始检查并安装依赖: vnstat, jq, curl, bc..."
    for pkg in vnstat jq curl bc; do
        if ! command -v $pkg &>/dev/null; then
            info "$pkg 未安装，开始安装..."
            if [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg || { err "安装 $pkg 失败"; exit 1; }
            elif [ -f /etc/alpine-release ]; then
                apk add --no-cache $pkg
            elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
                if command -v dnf &>/dev/null; then
                    dnf install -y $pkg
                else
                    yum install -y epel-release
                    yum install -y $pkg
                fi
            else
                warn "未识别系统，请确保已安装 $pkg"
            fi
        else
            info "$pkg 已安装"
        fi
    done
    info "依赖安装完成"
}

# ---------------- 生成配置 ----------------
generate_config() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [ -f "$CONFIG_FILE" ]; then
        info "配置文件已存在，保留原有配置"
        source "$CONFIG_FILE"
    fi

    read -rp "请输入每月流量重置日 (1-31, 默认${RESET_DAY:-1}): " input
    RESET_DAY=${input:-${RESET_DAY:-1}}

    read -rp "请输入 Telegram Bot Token (已配置请回车): " input
    BOT_TOKEN=${input:-${BOT_TOKEN:-}}

    read -rp "请输入 Telegram Chat ID (已配置请回车): " input
    CHAT_ID=${input:-${CHAT_ID:-}}

    read -rp "请输入每月流量总量 (GB, 0 不限制, 默认${MONTH_LIMIT_GB:-0}): " input
    MONTH_LIMIT_GB=${input:-${MONTH_LIMIT_GB:-0}}

    read -rp "请输入每日提醒小时 (0-23, 默认${DAILY_HOUR:-0}): " input
    DAILY_HOUR=${input:-${DAILY_HOUR:-0}}

    read -rp "请输入每日提醒分钟 (0-59, 默认${DAILY_MIN:-30}): " input
    DAILY_MIN=${input:-${DAILY_MIN:-30}}

    DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "请输入监控网卡 (默认 $DEFAULT_IFACE): " input
    IFACE=${input:-${IFACE:-$DEFAULT_IFACE}}

    read -rp "请输入流量告警阈值百分比 (默认${ALERT_PERCENT:-10}): " input
    ALERT_PERCENT=${input:-${ALERT_PERCENT:-10}}

    if [ -z "${HOSTNAME_CUSTOM:-}" ]; then
        read -rp "请输入主机名 (默认 $(hostname)): " input
        HOSTNAME_CUSTOM=${input:-$(hostname)}
    fi

    read -rp "是否启用每小时上传流量数据到服务器？(y/N): " input
    UPLOAD_ENABLE=${input,,}
    if [[ "$UPLOAD_ENABLE" == "y" ]]; then
        read -rp "请输入流量上传服务器 URL (例: https://example.com/upload): " SERVER_URL
    fi
    UPLOAD_ENABLE=${UPLOAD_ENABLE:-n}
    SERVER_URL="${SERVER_URL:-}"

    cat > "$CONFIG_FILE" <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
ALERT_PERCENT=$ALERT_PERCENT
HOSTNAME_CUSTOM="$HOSTNAME_CUSTOM"
UPLOAD_ENABLE="$UPLOAD_ENABLE"
SERVER_URL="$SERVER_URL"
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已保存：$CONFIG_FILE"
}

# ---------------- 生成主脚本 ----------------
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"

source "$CONFIG_FILE"

IFACE=${IFACE:-eth0}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
HOST=${HOSTNAME_CUSTOM:-$(hostname)}
IP=$(curl -4fsS --max-time 5 https://api.ipify.org || echo "未知")

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

format_bytes() {
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{split("B KB MB GB TB", u, " ");i=0; while(b>=1024 && i<4){b/=1024;i++} printf "%.2f%s",b,u[i+1]}'
}

get_vnstat_json() {
    vnstat -i "$IFACE" --json 2>/dev/null || echo '{}'
}

VNSTAT_JSON=$(get_vnstat_json)
VNSTAT_VERSION=$(vnstat --version | head -n1 | awk '{print $2}' | cut -d'.' -f1)
KIB_TO_BYTES=$(( VNSTAT_VERSION >=2 ? 1 : 1024 ))

if echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length>0' &>/dev/null; then
    TRAFFIC_PATH="day"
elif echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.days // [] | length>0' &>/dev/null; then
    TRAFFIC_PATH="days"
else
    TRAFFIC_PATH="day"
fi

TARGET_DATE_STR="${1:-$(date -d "yesterday" '+%Y-%m-%d')}"
TARGET_Y=$(date -d "$TARGET_DATE_STR" '+%Y')
TARGET_M=$((10#$(date -d "$TARGET_DATE_STR" '+%m')))
TARGET_D=$((10#$(date -d "$TARGET_DATE_STR" '+%d')))

if [ ! -f "$STATE_FILE" ]; then
    CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx+.tx)]|add//0")
    CUR_SUM=$(echo "$CUR_SUM_UNIT*$KIB_TO_BYTES" | bc)
    echo "{\"last_snapshot_date\":\"$(date +%Y-%m-%d)\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
fi
SNAP_BYTES=$(jq -r '.snapshot_bytes//0' "$STATE_FILE")
SNAP_DATE=$(jq -r '.last_snapshot_date//empty' "$STATE_FILE")
CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx+.tx)]|add//0")
CUR_SUM=$(echo "$CUR_SUM_UNIT*$KIB_TO_BYTES"| bc)
USED_BYTES=$(echo "$CUR_SUM-$SNAP_BYTES"|bc)
[ "$(echo "$USED_BYTES<0"|bc)" -eq 1 ] && USED_BYTES=0
MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
REMAIN_BYTES=$(echo "$MONTH_LIMIT_BYTES-$USED_BYTES"|bc)
[ "$(echo "$REMAIN_BYTES<0"|bc)" -eq 1 ] && REMAIN_BYTES=0
PERCENT=0
if [ "$MONTH_LIMIT_BYTES" -gt 0 ]; then
    PERCENT=$(echo "scale=0;($USED_BYTES*100)/$MONTH_LIMIT_BYTES"|bc)
    [ "$PERCENT" -gt 100 ] && PERCENT=100
fi

BAR_LEN=10
FILLED=$((PERCENT*BAR_LEN/100))
BAR=""
for ((i=0;i<BAR_LEN;i++)); do
    if [ "$i" -lt "$FILLED" ]; then
        if [ "$PERCENT" -lt 70 ]; then BAR+="🟩"
        elif [ "$PERCENT" -lt 90 ]; then BAR+="🟨"
        else BAR+="🟥"
        fi
    else BAR+="⬜️"; fi
done

DAY_VALUES=$(echo "$VNSTAT_JSON" | jq -r \
  --argjson y "$TARGET_Y" --argjson m "$TARGET_M" --argjson d "$TARGET_D" --arg path "$TRAFFIC_PATH" '
    (.interfaces[0].traffic[$path]//[])|map(select(.date.year==$y and .date.month==$m and .date.day==$d))
    |if length>0 then "\(.[-1].rx//0) \(.[-1].tx//0)" else "0 0" end')
DAY_VALUES=${DAY_VALUES:-"0 0"}
IFS=' ' read -r DAY_RX_UNIT DAY_TX_UNIT <<< "$DAY_VALUES"
DAY_RX=$(echo "$DAY_RX_UNIT*$KIB_TO_BYTES"|bc)
DAY_TX=$(echo "$DAY_TX_UNIT*$KIB_TO_BYTES"|bc)
DAY_TOTAL=$(echo "$DAY_RX+$DAY_TX"|bc)

MSG="📊 VPS 流量日报


🖥 主机： $HOST
🌐 地址： $IP
💾 网卡： $IFACE
⏰ 时间： $(date '+%Y-%m-%d %H:%M:%S')

📆 昨日流量 ($TARGET_DATE_STR)
⬇️ 下载： $(format_bytes $DAY_RX)
⬆️ 上传： $(format_bytes $DAY_TX)
↕️ 总计： $(format_bytes $DAY_TOTAL)

📅 本周期流量 (自 $SNAP_DATE 起)
⏳ 已用： $(format_bytes $USED_BYTES)
⏳ 剩余： $(format_bytes $REMAIN_BYTES)
⌛ 总量： $(format_bytes $MONTH_LIMIT_BYTES)

🔃 重置： $RESET_DAY 号
🎯 进度： $BAR $PERCENT%"

REMAIN_PERCENT=$(echo "scale=0;($REMAIN_BYTES*100)/$MONTH_LIMIT_BYTES"|bc)
[ "$(echo "$REMAIN_PERCENT<0"|bc)" -eq 1 ] && REMAIN_PERCENT=0
if [ "$MONTH_LIMIT_BYTES" -gt 0 ] && [ "$ALERT_PERCENT" -gt 0 ] && [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
    MSG="$MSG
⚠️ 流量告警：剩余 $REMAIN_PERCENT% (≤ $ALERT_PERCENT%)"
fi

curl -s -X POST "$TG_API" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MSG" >/dev/null 2>&1

# ---------------- 上传到服务器 ----------------
if [[ "${UPLOAD_ENABLE:-n}" == "y" && -n "$SERVER_URL" ]]; then
    UPLOAD_IP=${IP:-$(curl -s4 https://api.ipify.org || echo "")}
    UPLOAD_JSON=$(jq -n \
        --arg ip "$UPLOAD_IP" \
        --argjson used "$USED_BYTES" \
        --argjson total "$MONTH_LIMIT_BYTES" \
        --arg recharge_date "$SNAP_DATE" \
        --argjson ts "$(date +%s)" \
        '{ip: $ip, used: $used, total: $total, recharge_date: $recharge_date, ts: $ts}')
    curl -s -X POST "$SERVER_URL" -H "Content-Type: application/json" -d "$UPLOAD_JSON" >/dev/null 2>&1
fi
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新 v$VERSION"
}

# ---------------- 生成上传脚本 ----------------
generate_upload_script() {
    cat > "$UPLOAD_SCRIPT_FILE" <<EOF
#!/bin/bash
CONFIG_FILE="$CONFIG_FILE"
source "\$CONFIG_FILE"
bash "$SCRIPT_FILE"
EOF
    chmod 750 "$UPLOAD_SCRIPT_FILE"
    info "上传脚本已生成"
}

# ---------------- systemd timer ----------------
generate_systemd() {
    source "$CONFIG_FILE" || { err "无法加载配置"; exit 1; }

    # 主脚本 timer
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
    info "每日 Telegram 定时任务已启用"

    # 上传 timer
    if [[ "$UPLOAD_ENABLE" == "y" ]]; then
        systemctl disable --now vps_vnstat_upload.timer 2>/dev/null || true
        cat > "$UPLOAD_SERVICE_FILE" <<EOF
[Unit]
Description=VPS vnStat Hourly Upload
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPLOAD_SCRIPT_FILE
EOF

        cat > "$UPLOAD_TIMER_FILE" <<EOF
[Unit]
Description=Hourly timer for VPS vnStat Upload

[Timer]
OnCalendar=hourly
Persistent=true
Unit=vps_vnstat_upload.service

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now vps_vnstat_upload.timer
        info "每小时上传定时任务已启用"
    fi
}

# ---------------- 卸载 ----------------
uninstall_all() {
    info "开始卸载 vps_vnstat_telegram..."
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    systemctl disable --now vps_vnstat_upload.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE" "$UPLOAD_SCRIPT_FILE" "$UPLOAD_SERVICE_FILE" "$UPLOAD_TIMER_FILE"
    rm -rf "$STATE_DIR"
    rm -f "/tmp/vps_vnstat_debug.log"
    systemctl daemon-reload
    info "卸载完成"
}

# ---------------- 主菜单 ----------------
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 $VERSION ---"
    echo "请选择操作："
    echo "1) 安装 (配置并安装)"
    echo "2) 升级 (更新脚本和服务，不修改配置)"
    echo "3) 卸载 (删除所有文件和定时任务)"
    echo "4) 退出"
    echo "5) 立即上传一次流量数据到服务器"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            generate_upload_script
            generate_systemd
            info "安装完成，定时任务已启用"
            info "查询指定日期流量：/usr/local/bin/vps_vnstat_telegram.sh YYYY-MM-DD"
            ;;
        2)
            generate_main_script
            generate_upload_script
            generate_systemd
            info "升级完成，定时任务已启用"
            ;;
        3)
            uninstall_all
            ;;
        4)
            info "操作已取消"
            ;;
        5)
            if [[ "${UPLOAD_ENABLE:-n}" == "y" && -n "$SERVER_URL" ]]; then
                info "开始立即上传..."
                bash "$UPLOAD_SCRIPT_FILE"
                info "上传完成"
            else
                warn "未启用上传功能或服务器地址未配置"
            fi
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

main
