#!/bin/bash
# vps_vnstat_telegram.sh
# VPS vnStat Telegram 流量统计脚本（自动生成配置 + systemd timer/cron）
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SCRIPT_PATH="/usr/local/bin/vps_vnstat_telegram.sh"

# ---------------------------
# helper functions
# ---------------------------
info() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*"; }
err()  { echo -e "[ERR] $*"; }

escape_md() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//_/\\_}"
    s="${s//*/\\*}"
    s="${s//[/\\[}"
    s="${s//]/\\]}"
    s="${s//(/\\(}"
    s="${s//)/\\)}"
    s="${s//#/\\#}"
    s="${s//+/\\+}"
    s="${s//-/\\-}"
    s="${s//=/\\=}"
    s="${s//./\\.}"
    s="${s//!/\\!}"
    echo "$s"
}

format_bytes() {
    local bytes="$1"
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then bytes=0; fi
    awk -v b="$bytes" 'BEGIN{
        split("B KB MB GB TB", u, " ");
        i=0;
        while(b>=1024 && i<4){ b=b/1024; i++; }
        if(i==0) { printf "%d%s", int(b+0.5), u[i+1]; }
        else { printf "%.2f%s", b, u[i+1]; }
    }'
}

generate_progress_bar() {
    local pct="$1"
    local full="🟩"
    local empty="⬜️"
    local length=10
    local filled=$((pct*length/100))
    local bar=""
    for ((i=0;i<filled;i++)); do bar+="$full"; done
    for ((i=filled;i<length;i++)); do bar+="$empty"; done
    echo "$bar"
}

get_flow_status() {
    local pct="$1"
    local alert="$2"
    if [ "$pct" -ge 100 ]; then
        echo "⚠️ 超过限额"
    elif [ "$pct" -ge "$alert" ]; then
        echo "⚡️ 接近上限"
    else
        echo "✅ 正常"
    fi
}

get_public_ip() {
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip" "https://ifconfig.co"; do
        ip=$(curl -fsS --max-time 6 "$url" 2>/dev/null || echo "")
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
    echo "无法获取"
}

get_vnstat_today_bytes() {
    local iface="$1"
    local rx tx total
    rx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].rx // 0')
    tx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].tx // 0')
    total=$((rx+tx))
    echo "$rx $tx $total"
}

get_vnstat_cumulative_bytes() {
    local iface="$1"
    local sum
    sum=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | ((.rx // 0) + (.tx // 0))] | add // 0')
    echo "${sum:-0}"
}

# ---------------------------
# 自动生成配置文件（如果不存在）
# ---------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在，正在生成 $CONFIG_FILE ..."
    read -rp "每月流量重置日（1-28/29/30/31）: " RESET_DAY
    read -rp "Telegram Bot Token: " BOT_TOKEN
    read -rp "Telegram Chat ID: " CHAT_ID
    read -rp "每月流量总量（GB, 0表示不限制）: " MONTH_LIMIT_GB
    read -rp "每日提醒小时（0-23）: " DAILY_HOUR
    read -rp "每日提醒分钟（0-59）: " DAILY_MIN
    read -rp "监控网卡（默认 eth0）: " IFACE
    IFACE=${IFACE:-eth0}
    read -rp "剩余流量告警百分比（默认10，0表示不告警）: " ALERT_PERCENT
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
    echo "配置文件已生成：$CONFIG_FILE"
else
    echo "检测到配置文件，读取配置..."
fi

# 读取配置
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ---------------------------
# 初始化 state
# ---------------------------
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

if [ ! -f "$STATE_FILE" ]; then
    CUR_SUM=$(get_vnstat_cumulative_bytes "$IFACE")
    NOW_DATE=$(date +%Y-%m-%d)
    cat > "$STATE_FILE" <<EOF
{
  "last_snapshot_date": "$NOW_DATE",
  "snapshot_bytes": $CUR_SUM
}
EOF
    chmod 600 "$STATE_FILE"
fi

SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")

# ---------------------------
# 计算流量
# ---------------------------
read DAY_RX DAY_TX DAY_TOTAL < <(get_vnstat_today_bytes "$IFACE")
CUR_SUM=$(get_vnstat_cumulative_bytes "$IFACE")
USED_BYTES=$((CUR_SUM - SNAP_BYTES))
[ "$USED_BYTES" -lt 0 ] && USED_BYTES=0

MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf("%.0f", g*1024*1024*1024)}')
[ "$MONTH_LIMIT_BYTES" -le 0 ] && REMAIN_BYTES=0 || REMAIN_BYTES=$((MONTH_LIMIT_BYTES - USED_BYTES))
[ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0

DAY_RX_H=$(format_bytes "$DAY_RX")
DAY_TX_H=$(format_bytes "$DAY_TX")
DAY_TOTAL_H=$(format_bytes "$DAY_TOTAL")
USED_H=$(format_bytes "$USED_BYTES")
REMAIN_H=$(format_bytes "$REMAIN_BYTES")
LIMIT_H=$(format_bytes "$MONTH_LIMIT_BYTES")
USED_PCT=$([ "$MONTH_LIMIT_BYTES" -gt 0 ] && echo $((USED_BYTES*100/MONTH_LIMIT_BYTES)) || echo 0)

# ---------------------------
# 构造消息
# ---------------------------
CUR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
HOST_NAME_ESC=$(escape_md "$(hostname)")
VPS_IP_ESC=$(escape_md "$(get_public_ip)")
IFACE_ESC=$(escape_md "$IFACE")

BAR=$(generate_progress_bar "$USED_PCT")
STATUS=$(get_flow_status "$USED_PCT" "$ALERT_PERCENT")

MSG="📊 *VPS 流量日报*
🖥️ ${HOST_NAME_ESC} | 🌐 ${VPS_IP_ESC} | 💾 ${IFACE_ESC}
⏰ ${CUR_DATE}

🔹 今日流量: ⬇️ ${DAY_RX_H} | ⬆️ ${DAY_TX_H} | 📦 ${DAY_TOTAL_H}
🔸 本周期: 📌 已用 ${USED_H} | 剩余 ${REMAIN_H} / 总量 ${LIMIT_H}

📊 进度: ${BAR} ${USED_PCT}% ⚡️ ${STATUS}
"

# 发送 Telegram 消息
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=$MSG" >/dev/null 2>&1 || true

# ---------------------------
# 每月重置日发送周期汇总
# ---------------------------
TODAY_DAY=$(date +%d | sed 's/^0*//')
if [ "$TODAY_DAY" -eq "$RESET_DAY" ]; then
    PERIOD_START=${SNAP_DATE:-起始}
    PERIOD_END=$(date +"%Y-%m-%d")
    PERIOD_MSG="📊 *VPS 流量周期汇总*
🖥️ ${HOST_NAME_ESC} | 🌐 ${VPS_IP_ESC} | 💾 ${IFACE_ESC}
⏰ ${CUR_DATE}

📌 本周期已用: ${USED_H} | 剩余: ${REMAIN_H} / 总量 ${LIMIT_H}
📊 进度: ${BAR} ${USED_PCT}% ⚡️ ${STATUS}
"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=$PERIOD_MSG" >/dev/null 2>&1 || true

    # 更新 snapshot
    cat > "$STATE_FILE" <<EOF
{
  "last_snapshot_date": "$(date +%Y-%m-%d)",
  "snapshot_bytes": $CUR_SUM
}
EOF
fi
