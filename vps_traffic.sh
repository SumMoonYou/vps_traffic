#!/bin/bash
# VPS vnStat Telegram 脚本（JSON解析，保证与命令行一致）

# ================== 配置 ==================
BOT_TOKEN=""  # ← 改成你的 Bot Token
CHAT_ID=""                                 		# ← 改成你的 Chat ID
RESET_DAY=10       # 每月几号重置
IFACE="eth0"       # vnStat监控网卡
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# ================== 主机信息 ==================
HOST_NAME=$(hostname)
VPS_IP=$(curl -s https://api.ipify.org 2>/dev/null)
[ -z "$VPS_IP" ] && VPS_IP="无法获取"

# ================== 时间信息 ==================
CUR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
CUR_MONTH=$(date +%Y-%m)
DAY_OF_MONTH=$(date +%d)
CURRENT_HOUR=$(date +%H)

# ================== 自动单位转换 ==================
format_bytes_int() {
    local bytes=$1
    [ -z "$bytes" ] && bytes=0
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi
    local unit=("B" "KB" "MB" "GB" "TB")
    local i=0
    while [ $bytes -ge 1024 ] && [ $i -lt 4 ]; do
        bytes=$((bytes / 1024))
        i=$((i + 1))
    done
    echo "${bytes}${unit[$i]}"
}

# ================== 获取 vnStat 流量 ==================
# 日流量
DAY_RX_BYTES=$(vnstat -i $IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].rx // 0')
DAY_TX_BYTES=$(vnstat -i $IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.day[-1].tx // 0')
DAY_TOTAL_BYTES=$((DAY_RX_BYTES + DAY_TX_BYTES))

# 月流量
MONTH_RX_BYTES=$(vnstat -i $IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.month[-1].rx // 0')
MONTH_TX_BYTES=$(vnstat -i $IFACE --json 2>/dev/null | jq '.interfaces[0].traffic.month[-1].tx // 0')
MONTH_TOTAL_BYTES=$((MONTH_RX_BYTES + MONTH_TX_BYTES))

# 转换单位
DAY_RX=$(format_bytes_int $DAY_RX_BYTES)
DAY_TX=$(format_bytes_int $DAY_TX_BYTES)
DAY_TOTAL=$(format_bytes_int $DAY_TOTAL_BYTES)

MONTH_RX=$(format_bytes_int $MONTH_RX_BYTES)
MONTH_TX=$(format_bytes_int $MONTH_TX_BYTES)
MONTH_TOTAL=$(format_bytes_int $MONTH_TOTAL_BYTES)

# ================== Telegram 日报 ==================
SEND_NOTICE=false
if [ "$CURRENT_HOUR" = "00" ] || [ -z "$1" ]; then
    SEND_NOTICE=true
fi

if [ "$SEND_NOTICE" = true ]; then
    MSG="📊 *VPS 流量日报*
🖥️ 主机: $HOST_NAME
🌐 IP: $VPS_IP
⏰ 时间: $CUR_DATE
💾 网卡: $IFACE
⬇️ 下载: $DAY_RX
⬆️ 上传: $DAY_TX
📦 当日总计: $DAY_TOTAL
🔁 重置日: 每月 $RESET_DAY 号"

    curl -s -X POST "$TG_API" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" >/dev/null 2>&1
fi

# ================== 月度汇总 ==================
if [ "$DAY_OF_MONTH" = "$RESET_DAY" ]; then
    MONTH_MSG="📊 *VPS 月度流量汇总*
🖥️ 主机: $HOST_NAME
🌐 IP: $VPS_IP
📅 月份: $CUR_MONTH
⬇️ 下载: $MONTH_RX
⬆️ 上传: $MONTH_TX
📦 总计: $MONTH_TOTAL"

    curl -s -X POST "$TG_API" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MONTH_MSG" >/dev/null 2>&1
fi
