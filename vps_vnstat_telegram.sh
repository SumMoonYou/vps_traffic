#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本 v1.3.0
set -euo pipefail
IFS=$'\n\t'

VERSION="v1.3.1"

CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

# ------------------------------
# 安装依赖 (优先 IPv4)
# ------------------------------
install_dependencies() {
    info "开始安装依赖: vnstat, jq, curl, bc..."
    if [ -f /etc/debian_version ]; then
        info "使用 IPv4 更新 apt 源..."
        apt update -o Acquire::ForceIPv4=true -y
        DEBIAN_FRONTEND=noninteractive apt install -y -o Acquire::ForceIPv4=true vnstat jq curl bc
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache vnstat jq curl bc
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
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

# ------------------------------
# 生成或加载配置
# ------------------------------
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
    read -rp "请输入每日提醒小时 (0-23, 默认0): " DAILY_HOUR
    DAILY_HOUR=${DAILY_HOUR:-0}
    read -rp "请输入每日提醒分钟 (0-59, 默认30): " DAILY_MIN
    DAILY_MIN=${DAILY_MIN:-30}

    DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "请输入监控网卡 (默认 $DEFAULT_IFACE): " IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    read -rp "请输入流量告警阈值百分比 (默认10): " ALERT_PERCENT
    ALERT_PERCENT=${ALERT_PERCENT:-10}

    # 主机名，首次输入
    read -rp "请输入主机名 (留空使用系统默认): " CUSTOM_HOST
    if [ -z "$CUSTOM_HOST" ]; then
        CUSTOM_HOST=$(hostname)
    fi

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    cat > "$CONFIG_FILE" <<EOF
VERSION="$VERSION"
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
ALERT_PERCENT=$ALERT_PERCENT
CUSTOM_HOST="$CUSTOM_HOST"
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已保存：$CONFIG_FILE"
}

# ------------------------------
# 生成主脚本
# ------------------------------
generate_main_script() {
cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh (最鲁棒兼容版)
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
DEBUG_LOG="/tmp/vps_vnstat_debug.log"

debug_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$DEBUG_LOG"; }

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

HOST=${CUSTOM_HOST:-$(hostname)}
IFACE=${IFACE:-eth0}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
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

# 日期解析
TARGET_DATE_STR=${1:-$(date -d "yesterday" '+%Y-%m-%d')}
if ! date -d "$TARGET_DATE_STR" &>/dev/null; then
    TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')
fi
TARGET_Y=$(date -d "$TARGET_DATE_STR" '+%Y')
TARGET_M=$((10#$(date -d "$TARGET_DATE_STR" '+%m')))
TARGET_D=$((10#$(date -d "$TARGET_DATE_STR" '+%d')))

VNSTAT_JSON=$(get_vnstat_json)
VNSTAT_VERSION=$(vnstat --version | head -n1 | awk '{print $2}' | cut -d'.' -f1)
KIB_TO_BYTES=$([ "$VNSTAT_VERSION" -ge 2 ] && echo 1 || echo 1024)
TRAFFIC_PATH=$(echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // empty' &>/dev/null && echo day || echo days)

# 流量数据
DAY_VALUES=$(echo "$VNSTAT_JSON" | jq -r --argjson y "$TARGET_Y" --argjson m "$TARGET_M" --argjson d "$TARGET_D" --arg path "$TRAFFIC_PATH" '(.interfaces[0].traffic[$path] // []) | map(select(.date.year==$y and .date.month==$m and .date.day==$d)) | if length>0 then "\(.[-1].rx // 0) \(.[-1].tx // 0)" else "0 0" end')
DAY_VALUES=${DAY_VALUES:-"0 0"}
IFS=' ' read -r DAY_RX_UNIT DAY_TX_UNIT <<< "$DAY_VALUES"
DAY_RX=$(echo "$DAY_RX_UNIT * $KIB_TO_BYTES" | bc)
DAY_TX=$(echo "$DAY_TX_UNIT * $KIB_TO_BYTES" | bc)
DAY_TOTAL=$(echo "$DAY_RX + $DAY_TX" | bc)

# 周期快照
CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx + .tx)] | add // 0")
CUR_SUM=$(echo "$CUR_SUM_UNIT * $KIB_TO_BYTES" | bc)
if [ -f "$STATE_FILE" ]; then
    SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")
    SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
else
    SNAP_BYTES=$CUR_SUM
    SNAP_DATE=$(date +%Y-%m-%d)
    echo "{\"last_snapshot_date\":\"$SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
fi

USED_BYTES=$(echo "$CUR_SUM - $SNAP_BYTES" | bc)
[ "$(echo "$USED_BYTES < 0" | bc)" -eq 1 ] && USED_BYTES=0
MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
if [ "$MONTH_LIMIT_BYTES" -le 0 ]; then
    REMAIN_BYTES=0
else
    REMAIN_BYTES=$(echo "$MONTH_LIMIT_BYTES - $USED_BYTES" | bc)
fi
[ "$(echo "$REMAIN_BYTES < 0" | bc)" -eq 1 ] && REMAIN_BYTES=0

PERCENT=0
if [ "$MONTH_LIMIT_BYTES" -gt 0 ]; then
    PERCENT=$(echo "scale=0; ($USED_BYTES * 100) / $MONTH_LIMIT_BYTES" | bc)
    [ "$PERCENT" -gt 100 ] && PERCENT=100
fi

# 进度条
BAR_LEN=10
FILLED=$((PERCENT*BAR_LEN/100))
BAR=""
for ((i=0;i<BAR_LEN;i++)); do
    if [ "$i" -lt "$FILLED" ]; then
        if [ "$PERCENT" -lt 70 ]; then BAR+="🟩"
        elif [ "$PERCENT" -lt 90 ]; then BAR+="🟨"
        else BAR+="🟥"
        fi
    else
        BAR+="⬜️"
    fi
done

# 消息
MSG="📊 VPS 流量日报 ($VERSION)

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

🎯 进度： $BAR $PERCENT%"

# 告警
if [ "$MONTH_LIMIT_BYTES" -gt 0 ] && [ "$ALERT_PERCENT" -gt 0 ]; then
    REMAIN_PERCENT=$(echo "scale=0; ($REMAIN_BYTES * 100)/$MONTH_LIMIT_BYTES" | bc)
    [ "$(echo "$REMAIN_PERCENT < 0" | bc)" -eq 1 ] && REMAIN_PERCENT=0
    if [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
        MSG="$MSG
⚠️ 流量告警：剩余 $REMAIN_PERCENT% (≤ $ALERT_PERCENT%)"
    fi
fi

curl -s -X POST "$TG_API" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MSG" >/dev/null 2>&1
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已生成 /usr/local/bin/vps_vnstat_telegram.sh"
}

# ------------------------------
# systemd 定时任务
# ------------------------------
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

# ------------------------------
# 卸载
# ------------------------------
uninstall_all() {
    info "开始卸载 vps_vnstat_telegram..."
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    rm -f "/tmp/vps_vnstat_debug.log"
    systemctl daemon-reload
    info "卸载完成。"
}

# ------------------------------
# 主菜单
# ------------------------------
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 $VERSION ---"
    echo "请选择操作："
    echo "1) 安装 (自动安装依赖、配置、设置定时任务)"
    echo "2) 升级 (保留配置，重新生成脚本和定时任务)"
    echo "3) 卸载 (删除所有文件和定时任务)"
    echo "4) 退出"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            generate_systemd
            info "安装完成，调试日志：/tmp/vps_vnstat_debug.log"
            info "要查询指定日期流量，请运行：/usr/local/bin/vps_vnstat_telegram.sh YYYY-MM-DD"
            ;;
        2)
            install_dependencies
            generate_main_script
            generate_systemd
            info "升级完成，保留原有配置。"
            ;;
        3)
            uninstall_all
            ;;
        4)
            info "操作已取消。"
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

main
