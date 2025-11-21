#!/bin/bash
# install_vps_vnstat.sh
# 一键安装/卸载 VPS vnStat Telegram 流量日报脚本（systemd timer，去重，默认每日23:59）
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

# 安装依赖
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

# 生成配置
generate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "配置文件已存在：$CONFIG_FILE"
        return
    fi
    read -rp "请输入每月流量重置日 (1-28/29/30/31): " RESET_DAY
    read -rp "请输入 Telegram Bot Token: " BOT_TOKEN
    read -rp "请输入 Telegram Chat ID: " CHAT_ID
    read -rp "请输入每月流量总量 (GB, 0 不限制): " MONTH_LIMIT_GB

    # 默认每日提醒 23:59
    read -rp "请输入每日提醒小时 (0-23, 默认23): " DAILY_HOUR
    DAILY_HOUR=${DAILY_HOUR:-23}

    read -rp "请输入每日提醒分钟 (0-59, 默认59): " DAILY_MIN
    DAILY_MIN=${DAILY_MIN:-59}

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

# --- 关键修复：强制使用 UTF-8 语言环境 ---
export LANG=en_US.UTF-8
# ----------------------------------------

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

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

if [ -f "$STATE_FILE" ]; then
    SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")
    SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
else
    SNAP_BYTES=0
    SNAP_DATE=$(date +%Y-%m-%d)
    CUR_SUM=$(vnstat -i "$IFACE" --json | jq '[.interfaces[0].traffic.day[]? | (.rx + .tx)] | add // 0')
    echo "{\"last_snapshot_date\":\"$SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
fi

# 计算昨日日期（用于过滤 vnstat 数据）
YESTERDAY_YEAR=$(date -d "yesterday" +%Y)
YESTERDAY_MONTH=$(date -d "yesterday" +%m)
YESTERDAY_DAY=$(date -d "yesterday" +%d)
YESTERDAY_DATE=$(date -d "yesterday" '+%Y-%m-%d')

DAY_RX=0
DAY_TX=0
DAY_TOTAL=0

DAY_JSON=$(vnstat -i "$IFACE" --json || echo '{}')
DAY_JSON=${DAY_JSON:-'{}'}

# 使用昨日日期过滤流量数据
DAY_VALUES=$(echo "$DAY_JSON" | jq -r --arg yy "$YESTERDAY_YEAR" --arg mm "$YESTERDAY_MONTH" --arg dd "$YESTERDAY_DAY" '
  .interfaces[0].traffic.day // []
  | map(select(.date.year == ($yy|tonumber)
               and .date.month == ($mm|tonumber)
               and .date.day == ($dd|tonumber)))
  | if length>0 then
      (.[-1].rx) as $rx | (.[-1].tx) as $tx | "\($rx) \($tx) \($rx + $tx)"
    else "0 0 0" end
')
DAY_VALUES=${DAY_VALUES:-"0 0 0"}
read -r DAY_RX DAY_TX DAY_TOTAL <<< "$DAY_VALUES"

CUR_SUM=$(echo "$DAY_JSON" | jq '[.interfaces[0].traffic.day[]? | (.rx + .tx)] | add // 0')
USED_BYTES=$((CUR_SUM - SNAP_BYTES))
[ "$USED_BYTES" -lt 0 ] && USED_BYTES=0

MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
[ "$MONTH_LIMIT_BYTES" -le 0 ] && REMAIN_BYTES=0 || REMAIN_BYTES=$((MONTH_LIMIT_BYTES - USED_BYTES))
[ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0

PERCENT=0
[ "$MONTH_LIMIT_BYTES" -gt 0 ] && PERCENT=$((USED_BYTES*100/MONTH_LIMIT_BYTES))
BAR_LEN=10
FILLED=$((PERCENT*BAR_LEN/100))
BAR=""
for ((i=0;i<BAR_LEN;i++)); do
    if [ "$i" -lt "$FILLED" ]; then
        if [ "$PERCENT" -lt 70 ]; then BAR+="??"
        elif [ "$PERCENT" -lt 90 ]; then BAR+="??"
        else BAR+="??"
        fi
    else
        BAR+="??"
    fi
done

MSG="?? VPS 流量日报

??? 主机: $HOST
?? IP: $IP
?? 网卡: $IFACE
? 时间: $(date '+%Y-%m-%d %H:%M:%S')

?? 昨日流量 ($YESTERDAY_DATE)
?? 下载: $(format_bytes $DAY_RX)   ?? 上传: $(format_bytes $DAY_TX)   ?? 总计: $(format_bytes $DAY_TOTAL)

?? 本周期流量 (自 $SNAP_DATE 起)
?? 已用: $(format_bytes $USED_BYTES)   剩余: $(format_bytes $REMAIN_BYTES) / 总量: $(format_bytes $MONTH_LIMIT_BYTES)
?? 进度: $BAR $PERCENT%"

if [ "$MONTH_LIMIT_BYTES" -gt 0 ] && [ "$ALERT_PERCENT" -gt 0 ]; then
    REMAIN_PERCENT=$((REMAIN_BYTES*100/MONTH_LIMIT_BYTES))
    if [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
        MSG="$MSG
?? 流量告警：剩余 $REMAIN_PERCENT% (≤ $ALERT_PERCENT%)"
    fi
fi

# 使用 -sS 确保在失败时打印错误信息到日志
curl -sS -X POST "$TG_API" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$MSG"
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本生成完成并设置可执行权限：$SCRIPT_FILE"
}

# 生成 systemd timer（只保留一个）
generate_systemd() {
    # 停用并删除旧 timer
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true

    # service
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS vnStat Telegram Daily Report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

    # timer
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily timer for VPS vnStat Telegram Report

[Timer]
OnCalendar=*-*-* ${DAILY_HOUR:-23}:${DAILY_MIN:-59}:00
Persistent=true
Unit=vps_vnstat_telegram.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
    info "systemd timer 已启用，确保每天只存在一个 vps_vnstat_telegram.timer"
}

# 卸载
uninstall_all() {
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload
    info "卸载完成。"
}

# 主菜单
main() {
    echo "请选择操作："
    echo "1) 安装"
    echo "2) 卸载"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            # shellcheck source=/dev/null
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
