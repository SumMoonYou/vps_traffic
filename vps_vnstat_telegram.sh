#!/bin/bash
# /usr/local/bin/vps_vnstat_telegram.sh
# 每日执行：推送当日流量 + 本周期已用/剩余；在重置日推送周期汇总并更新 snapshot
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"

# -----------------------------
# 加载配置
# -----------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}
RESET_DAY=${RESET_DAY:-1}
IFACE=${IFACE:-eth0}
BOT_TOKEN=${BOT_TOKEN:-}
CHAT_ID=${CHAT_ID:-}

# -----------------------------
# 获取主机名 / IP / 网卡
# -----------------------------
HOST_NAME=$(hostname -f 2>/dev/null || hostname || echo "未知主机")
VPS_IP=$(curl -fsS https://api.ipify.org 2>/dev/null || echo "未知IP")
IFACE=${IFACE:-eth0}

# -----------------------------
# Markdown 转义
# -----------------------------
escape_md() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//_/\\_}"
    echo "$s"
}
HOST_NAME_ESC=$(escape_md "$HOST_NAME")
VPS_IP_ESC=$(escape_md "$VPS_IP")
IFACE_ESC=$(escape_md "$IFACE")

# -----------------------------
# 字节格式化
# -----------------------------
format_bytes() {
    local bytes="$1"
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then bytes=0; fi
    awk -v b="$bytes" 'BEGIN{
        split("B KB MB GB TB", u, " ");
        i=0;
        while(b>=1024 && i<4){ b=b/1024; i++; }
        if(i==0){ printf "%d%s", int(b+0.5), u[i+1]; }
        else{ printf "%.2f%s", b, u[i+1]; }
    }'
}

# -----------------------------
# vnStat 数据获取
# -----------------------------
get_vnstat_cumulative_days_bytes() {
    local iface="$1"
    local sum
    sum=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | ((.rx // 0) + (.tx // 0))] | add // 0' 2>/dev/null || echo "0")
    echo "${sum:-0}"
}

get_vnstat_today_bytes() {
    local iface="$1"
    local rx tx total
    rx=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | select(.date.day == (now|strftime("%d")|tonumber)) | .rx] | first // empty' 2>/dev/null || echo "")
    tx=$(vnstat -i "$iface" --json 2>/dev/null | jq '[.interfaces[0].traffic.day[]? | select(.date.day == (now|strftime("%d")|tonumber)) | .tx] | first // empty' 2>/dev/null || echo "")
    if ! [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
        rx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].rx // 0' 2>/dev/null || echo "0")
        tx=$(vnstat -i "$iface" --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].tx // 0' 2>/dev/null || echo "0")
    fi
    rx=${rx:-0}; tx=${tx:-0}
    total=$((rx + tx))
    echo "$rx $tx $total"
}

# -----------------------------
# snapshot 初始化 / 读取 / 写入
# -----------------------------
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
        SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE" 2>/dev/null || echo "0")
    else
        SNAP_DATE=""; SNAP_BYTES=0
    fi
}

write_snapshot() {
    local new_bytes="$1"
    local new_date
    new_date=$(date +%Y-%m-%d)
    cat > "$STATE_FILE" <<EOF
{
  "last_snapshot_date": "$new_date",
  "snapshot_bytes": $new_bytes
}
EOF
    chmod 600 "$STATE_FILE"
}

# -----------------------------
# 流量状态判断
# -----------------------------
get_flow_status() {
    local pct_remain="$1"
    local alert_percent="$2"
    local status="✅ 正常"

    if [ "$pct_remain" -le "$alert_percent" ] && [ "$alert_percent" -gt 0 ]; then
        status="⚠️ 剩余流量低于 ${alert_percent}%！"
    elif [ "$pct_remain" -le 20 ]; then
        status="⚡️ 接近上限"
    fi
    echo "$status"
}

# -----------------------------
# 进度条生成
# -----------------------------
generate_progress_bar() {
    local pct="$1"
    local len=10
    local filled=$((pct * len / 100))
    [ "$filled" -gt "$len" ] && filled=$len
    local empty=$((len - filled))
    local bar=""
    
    local color
    if [ "$pct" -le 50 ]; then color="🟩"
    elif [ "$pct" -le 80 ]; then color="🟨"
    else color="🟥"; fi
    
    for ((i=0;i<filled;i++)); do bar+="$color"; done
    for ((i=0;i<empty;i++)); do bar+="⬜️"; done
    echo "$bar"
}

# -----------------------------
# Telegram 消息发送
# -----------------------------
send_message() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

# -----------------------------
# Telegram 消息模板
# -----------------------------
generate_tg_message() {
    local title="$1"
    local cur_date="$2"
    local day_rx="$3"
    local day_tx="$4"
    local day_total="$5"
    local used="$6"
    local remain="$7"
    local limit="$8"
    local pct="$9"

    local bar=$(generate_progress_bar "$pct")
    local status=$(get_flow_status "$pct" "$ALERT_PERCENT")

    cat <<EOF
📊 ${title}

🖥️ 主机: ${HOST_NAME_ESC}
🌐 IP: ${VPS_IP_ESC}
💾 网卡: ${IFACE_ESC}
⏰ 时间: ${cur_date}

🔹 今日流量
⬇️ 下载 : ${day_rx}
⬆️ 上传 : ${day_tx}
📦 总计 : ${day_total}

🔸 本周期流量 (${SNAP_DATE_ESC} → ${cur_date})
📌 已使用 : ${used}
📌 剩余 : ${remain} / ${limit}

📊 进度 : ${bar} ${pct}%
⚡️ 流量状态: ${status}
EOF
}

# -----------------------------
# 主逻辑
# -----------------------------
main() {
    init_state_if_missing
    read_snapshot

    # 今日流量
    read DAY_RX DAY_TX DAY_TOTAL < <(get_vnstat_today_bytes "$IFACE")

    # 当前累计
    CUR_SUM=$(get_vnstat_cumulative_days_bytes "$IFACE")
    USED_BYTES=$(( CUR_SUM - SNAP_BYTES ))
    [ "$USED_BYTES" -lt 0 ] && USED_BYTES=0

    MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf("%.0f", g*1024*1024*1024)}')
    REMAIN_BYTES=$(( MONTH_LIMIT_BYTES - USED_BYTES ))
    [ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0
    [ "$MONTH_LIMIT_BYTES" -le 0 ] && REMAIN_BYTES=0

    DAY_RX_H=$(format_bytes "$DAY_RX")
    DAY_TX_H=$(format_bytes "$DAY_TX")
    DAY_TOTAL_H=$(format_bytes "$DAY_TOTAL")
    USED_H=$(format_bytes "$USED_BYTES")
    REMAIN_H=$(format_bytes "$REMAIN_BYTES")
    LIMIT_H=$(format_bytes "$MONTH_LIMIT_BYTES")

    PCT_REMAIN=0
    [ "$MONTH_LIMIT_BYTES" -gt 0 ] && PCT_REMAIN=$(( REMAIN_BYTES*100/MONTH_LIMIT_BYTES ))

    CUR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
    SNAP_DATE_ESC=$(escape_md "${SNAP_DATE:-起始}")

    # 日报
    MSG=$(generate_tg_message "VPS 流量日报" "$CUR_DATE" "$DAY_RX_H" "$DAY_TX_H" "$DAY_TOTAL_H" "$USED_H" "$REMAIN_H" "$LIMIT_H" "$PCT_REMAIN")
    send_message "$MSG"

    # 周期汇总
    TODAY_DAY=$(date +%d | sed 's/^0*//')
    if [ "$TODAY_DAY" -eq "$RESET_DAY" ]; then
        PERIOD_END=$(date +"%Y-%m-%d")
        PERIOD_MSG=$(generate_tg_message "VPS 流量周期汇总" "$PERIOD_END" "-" "-" "-" "$USED_H" "$REMAIN_H" "$LIMIT_H" "$PCT_REMAIN")
        send_message "$PERIOD_MSG"
        write_snapshot "$CUR_SUM"
    fi
}

main "$@"
