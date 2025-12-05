#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本
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
err() { echo -e "[\e[31mERR\e[0m] $*"; }

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
    
    # 主机名配置
    if ! grep -q "HOSTNAME=" "$CONFIG_FILE"; then
        read -rp "请输入主机名 (默认使用当前主机名): " USER_HOSTNAME
        USER_HOSTNAME=${USER_HOSTNAME:-$(hostname)}
        info "主机名设置为：$USER_HOSTNAME"
    else
        USER_HOSTNAME=$(grep "HOSTNAME=" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')
    fi

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
HOSTNAME="$USER_HOSTNAME"
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

# 生成主脚本 (最鲁棒兼容版)
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh (最鲁棒兼容版：修复所有已知问题)
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
DEBUG_LOG="/tmp/vps_vnstat_debug.log"

# --- 调试函数 ---
debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$DEBUG_LOG"
}
# --- 调试函数结束 ---

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# 获取主机名
HOSTNAME=${HOSTNAME:-$(grep "HOSTNAME=" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"')}

# --- JSON 获取函数 (确保只返回 JSON，避免 jq 字符串错误) ---
get_vnstat_json() {
    vnstat -i "$IFACE" --json 2>/dev/null || echo '{}'
}

# --- 兼容性设置 ---
VNSTAT_JSON=$(get_vnstat_json)

VNSTAT_VERSION=$(vnstat --version | head -n1 | awk '{print $2}' | cut -d'.' -f1)

if [ "$VNSTAT_VERSION" -ge 2 ]; then
    KIB_TO_BYTES=1
else
    KIB_TO_BYTES=1024
fi

if echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length > 0' &>/dev/null; then
    TRAFFIC_PATH="day"
elif echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.days // [] | length > 0' &>/dev/null; then
    TRAFFIC_PATH="days"
else
    TRAFFIC_PATH="day"
fi

TARGET_DATE_STR=""
MODE="Daily Report"

if [ $# -gt 0 ]; then
    TARGET_DATE_STR="$1"
    MODE="Specific Date Report"
    if ! date -d "$TARGET_DATE_STR" +%Y-%m-%d &>/dev/null; then
        TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')
        MODE="Daily Report (Fallback)"
    fi
else
    TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')
fi

TARGET_Y=$(date -d "$TARGET_DATE_STR" '+%Y')
TARGET_M=$((10#$(date -d "$TARGET_DATE_STR" '+%m')))
TARGET_D=$((10#$(date -d "$TARGET_DATE_STR" '+%d')))

IFACE=${IFACE:-eth0}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}

TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
HOST=$(hostname)
IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "未知")

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

format_bytes() {
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{split("B KB MB GB TB", u, " ");i=0; while(b>=1024 && i<4){b/=1024;i++} printf "%.2f%s",b,u[i+1]}'
}

# 周期流量计算及月度重置
if [ "$MODE" != "Specific Date Report" ]; then
    VNSTAT_JSON=$(get_vnstat_json)

    CURRENT_DAY=$(date +%d)
    CURRENT_DAY=$((10#$CURRENT_DAY))
    RESET_DAY=${RESET_DAY:-1}

    if [ -f "$STATE_FILE" ]; then
        LAST_SNAP_DATE=$(jq -r '.last_snapshot_date // "1970-01-01"' "$STATE_FILE")
        LAST_SNAP_DAY=$(date -d "$LAST_SNAP_DATE" +%d)
        LAST_SNAP_DAY=$((10#$LAST_SNAP_DAY))
    else
        LAST_SNAP_DAY=0
    fi

    if [ "$CURRENT_DAY" -eq "$RESET_DAY" ] && [ "$CURRENT_DAY" -ne "$LAST_SNAP_DAY" ]; then
        CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx + .tx)] | add // 0")
        CUR_SUM=$(echo "$CUR_SUM_UNIT * $KIB_TO_BYTES" | bc)
        NEW_SNAP_DATE=$(date +%Y-%m-%d)
        echo "{\"last_snapshot_date\":\"$NEW_SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
    fi
    
    if [ -f "$STATE_FILE" ]; then
        SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")
        SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
    else
        SNAP_BYTES=0
        SNAP_DATE=$(date +%Y-%m-%d)
        CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx + .tx)] | add // 0")
        CUR_SUM=$(echo "$CUR_SUM_UNIT * $KIB_TO_BYTES" | bc)
        echo "{\"last_snapshot_date\":\"$SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
        SNAP_BYTES=$CUR_SUM
    fi

    CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx + .tx)] | add // 0")
    CUR_SUM=$(echo "$CUR_SUM_UNIT * $KIB_TO_BYTES" | bc)

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
fi

# 提取目标日期的流量
VNSTAT_JSON=$(get_vnstat_json)

DAY_VALUES=$(echo "$VNSTAT_JSON" | jq -r \
  --argjson y "$TARGET_Y" \
  --argjson m "$TARGET_M" \
  --argjson d "$TARGET_D" \
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

# 消息模板
if [ "$MODE" == "Specific Date Report" ]; then
    MSG="📊 VPS 指定日期流量查询

🖥 主机: $HOSTNAME
🌐 地址： $IP
💾 网卡: $IFACE
⏰ 查询时间: $(date '+%Y-%m-%d %H:%M:%S')

📅 目标日期流量 ($TARGET_DATE_STR)
⬇️ 下载: $(format_bytes $DAY_RX)
⬆️ 上传: $(format_bytes $DAY_TX)
↕️ 总计: $(format_bytes $DAY_TOTAL)"
else
    MSG="📊 VPS 流量日报

🖥 主机： $HOSTNAME
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
fi

curl -s -X POST "$TG_API" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$MSG" >/dev/null 2>&1
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新，修复了所有已知的兼容性问题，并提高了鲁棒性。"
}

# 生成 systemd timer
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

# 卸载
uninstall_all() {
    info "开始卸载 vps_vnstat_telegram..."
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    rm -f "/tmp/vps_vnstat_debug.log"
    systemctl daemon-reload
    info "卸载完成。"
}

# 主菜单
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 (最鲁棒兼容版) ---"
    echo "请选择操作："
    echo "1) 安装 (自动安装依赖、配置、设置定时任务)"
    echo "2) 卸载 (删除所有文件和定时任务)"
    echo "3) 退出"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            generate_systemd
            info "所有安装步骤完成。定时任务已启用。"
            info "调试日志文件位于 /tmp/vps_vnstat_debug.log"
            info "要查询指定日期流量，请运行：/usr/local/bin/vps_vnstat_telegram.sh YYYY-MM-DD"
            ;;
        2)
            uninstall_all
            ;;
        3)
            info "操作已取消。"
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

main
