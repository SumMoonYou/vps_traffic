set -u

VERSION="v1.9"
CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

# ---------------- 1. 依赖与初始化 ----------------
install_dependencies() {
    info "正在安装依赖..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y vnstat jq curl bc
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache vnstat jq curl bc
    else
        yum install -y epel-release && yum install -y vnstat jq curl bc
    fi
    systemctl enable --now vnstat 2>/dev/null || true
    
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    ACTIVE_IFACE=${IFACE:-eth0}
    vnstat --add -i "$ACTIVE_IFACE" 2>/dev/null || true
    systemctl restart vnstat 2>/dev/null || true
    info "依赖安装完成。"
}

# ---------------- 2. 配置引导 ----------------
generate_config() {
    mkdir -p "$STATE_DIR"
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    echo "--- 配置引导 ---"
    read -rp "每月重置日 (1-31, 默认 ${RESET_DAY:-1}): " input; RESET_DAY=${input:-${RESET_DAY:-1}}
    read -rp "TG Bot Token: " input; BOT_TOKEN=${input:-${BOT_TOKEN:-}}
    read -rp "TG Chat ID: " input; CHAT_ID=${input:-${CHAT_ID:-}}
    read -rp "月流量总量 (GB, 0不限, 默认 ${MONTH_LIMIT_GB:-0}): " input; MONTH_LIMIT_GB=${input:-${MONTH_LIMIT_GB:-0}}
    read -rp "推送时间-小时 (0-23, 默认 ${DAILY_HOUR:-0}): " input; DAILY_HOUR=${input:-${DAILY_HOUR:-0}}
    read -rp "推送时间-分钟 (0-59, 默认 ${DAILY_MIN:-30}): " input; DAILY_MIN=${input:-${DAILY_MIN:-30}}
    
    DF_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "网卡名称 (默认 $DF_IF): " input; IFACE=${input:-${IFACE:-$DF_IF}}
    
    [ -z "${HOSTNAME_CUSTOM:-}" ] && read -rp "主机名 (默认 $(hostname)): " input && HOSTNAME_CUSTOM=${input:-$(hostname)}
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
HOSTNAME_CUSTOM="$HOSTNAME_CUSTOM"
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已更新。"
}

# ---------------- 3. 主逻辑脚本 (整合补丁) ----------------
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
set -u
if [ ! -f "/etc/vps_vnstat_config.conf" ]; then exit 1; fi
source "/etc/vps_vnstat_config.conf"
STATE_FILE="/var/lib/vps_vnstat_telegram/state.json"
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

HOST=${HOSTNAME_CUSTOM:-$(hostname)}
IP=$(curl -4fsS --max-time 5 https://api.ipify.org || echo "未知")

# 数据采集
vnstat -u -i "$IFACE" >/dev/null 2>&1 || true
VNSTAT_JSON=$(vnstat -i "$IFACE" --json 2>/dev/null || echo '{}')
VNSTAT_VERSION=$(vnstat --version 2>/dev/null | head -n1 | awk '{print $2}' | cut -d'.' -f1 || echo "2")
KIB_TO_BYTES=$(( VNSTAT_VERSION >=2 ? 1 : 1024 ))
TRAFFIC_PATH=$(echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length>0' &>/dev/null && echo "day" || echo "days")

format_b() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=0;while(b>=1024&&i<4){b/=1024;i++}printf "%.2f%s",b,u[i+1]}'; }

# --- 昨日流量 ---
T_STR="${1:-$(date -d "yesterday" '+%Y-%m-%d')}"
T_Y=$(date -d "$T_STR" '+%Y'); T_M=$((10#$(date -d "$T_STR" '+%m'))); T_D=$((10#$(date -d "$T_STR" '+%d')))
DAY_DATA=$(echo "$VNSTAT_JSON" | jq -r --argjson y $T_Y --argjson m $T_M --argjson d $T_D --arg p "$TRAFFIC_PATH" \
    '.interfaces[0].traffic[$p][]? | select(.date.year==$y and .date.month==$m and .date.day==$d) | "\(.rx) \(.tx)"' 2>/dev/null)
read -r D_RX_U D_TX_U <<< "${DAY_DATA:-0 0}"
D_RX=$(echo "$D_RX_U*$KIB_TO_BYTES" | bc); D_TX=$(echo "$D_TX_U*$KIB_TO_BYTES" | bc); D_TOTAL=$(echo "$D_RX+$D_TX" | bc)

# --- 周期推算 ---
CUR_Y=$(date +%Y); CUR_M=$((10#$(date +%m))); DOM=$((10#$(date +%d)))
if [ "$DOM" -lt "$RESET_DAY" ]; then
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY -1 month" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
else
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY +1 month" +%Y-%m-%d)
fi

# --- 周期流量计算 (整合扫描逻辑) ---
ACC_RX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .rx]|add//0" 2>/dev/null)
ACC_TX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .tx]|add//0" 2>/dev/null)
ACC_TOTAL=$(echo "($ACC_RX_U+$ACC_TX_U)*$KIB_TO_BYTES" | bc)

# 核心：自动扫描数据库对齐历史数据
if [ ! -f "$STATE_FILE" ]; then
    S_Y=$(date -d "$START_PERIOD" '+%Y'); S_M=$((10#$(date -d "$START_PERIOD" '+%m'))); S_D=$((10#$(date -d "$START_PERIOD" '+%d')))
    PERIOD_RAW=$(echo "$VNSTAT_JSON" | jq -r --argjson y $S_Y --argjson m $S_M --argjson d $S_D --arg p "$TRAFFIC_PATH" \
        '.interfaces[0].traffic[$p][]? | select(.date.year > $y or (.date.year == $y and .date.month > $m) or (.date.year == $y and .date.month == $m and .date.day >= $d)) | (.rx+.tx)' | awk '{s+=$1} END {print s+0}')
    USED_BYTES=$(echo "$PERIOD_RAW*$KIB_TO_BYTES" | bc)
    SNAP_BASE=$(echo "$ACC_TOTAL-$USED_BYTES" | bc)
    echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$SNAP_BASE}" > "$STATE_FILE"
else
    SNAP_TOTAL=$(jq -r '.snap_total//0' "$STATE_FILE")
    SNAP_DATE=$(jq -r '.last_snapshot_date//""' "$STATE_FILE")
    if [[ "$SNAP_DATE" < "$START_PERIOD" ]]; then
        echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$ACC_TOTAL}" > "$STATE_FILE"
        USED_BYTES=0
    else
        USED_BYTES=$(echo "$ACC_TOTAL-$SNAP_TOTAL" | bc)
    fi
fi

[ "$(echo "$USED_BYTES<0"|bc)" -eq 1 ] && USED_BYTES=0
LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
REMAIN_BYTES=$(echo "$LIMIT_BYTES-$USED_BYTES" | bc); [ "$(echo "$REMAIN_BYTES<0"|bc)" -eq 1 ] && REMAIN_BYTES=0
PERCENT=0; [ "$LIMIT_BYTES" -gt 0 ] && PERCENT=$(echo "($USED_BYTES*100)/$LIMIT_BYTES" | bc)
[ "$PERCENT" -gt 100 ] && PERCENT=100
BAR=""; FILLED=$((PERCENT*10/100)); for ((i=0;i<10;i++)); do [ "$i" -lt "$FILLED" ] && BAR+="🟦" || BAR+="⬜"; done

# --- 发送 ---
MSG="📊 *VPS 流量日报*


🖥 *主机*: $HOST
🌐 *地址*: $IP
💾 *网卡*: $IFACE
⏰ *时间*: $(date '+%Y-%m-%d %H:%M')

🗓 *昨日数据* ($T_STR)
📥 *下载*: $(format_b $D_RX)
📤 *上传*: $(format_b $D_TX)
↕️ *总计*: $(format_b $D_TOTAL)

🈷 *本周期统计*
🗓️ *区间*: \`$START_PERIOD\` ➔ \`$END_PERIOD\`
⏳️ *已用*: $(format_b $USED_BYTES)
⏳️ *剩余*: $(format_b $REMAIN_BYTES)
⌛️ *总量*: $(format_b $LIMIT_BYTES)
🔃 *重置*: 每月 $RESET_DAY 号

🎯 *进度*: $BAR $PERCENT%"

[ "$LIMIT_BYTES" -gt 0 ] && [ "$PERCENT" -ge $((100-ALERT_PERCENT)) ] && MSG="$MSG
⚠️ *告警*: 流量消耗已达 $PERCENT%！"

RESULT=$(curl -s -X POST "$TG_API" -d "chat_id=$CHAT_ID" -d "parse_mode=Markdown" --data-urlencode "text=$MSG")
if echo "$RESULT" | grep -q '"ok":true'; then echo "发送成功"; else echo "发送失败: $RESULT"; fi
EOS
    chmod 750 "$SCRIPT_FILE"
}

# ---------------- 4. Systemd ----------------
generate_systemd() {
    source "$CONFIG_FILE"
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    cat > /etc/systemd/system/vps_vnstat_telegram.service <<EOF
[Unit]
Description=VPS vnStat Telegram Report Service
[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF
    cat > /etc/systemd/system/vps_vnstat_telegram.timer <<EOF
[Unit]
Description=Timer for VPS vnStat Telegram Report
[Timer]
OnCalendar=*-*-* ${DAILY_HOUR}:${DAILY_MIN}:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
}

# ---------------- 5. 入口 ----------------
main() {
    echo "VPS vnStat Telegram 流量日报脚本 $VERSION"
    echo "1) 安装/更新配置"
    echo "2) 仅更新脚本逻辑"
    echo "3) 退出"
    read -rp "选择: " CH
    case "$CH" in
        1) install_dependencies; generate_config; generate_main_script; generate_systemd; info "全流程完成！";;
        2) generate_main_script; info "逻辑已更新。";;
        *) exit 0;;
    esac
}
main
