#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本 v1.3.6
set -euo pipefail
IFS=$'\n\t'

VERSION="v1.3.6"
CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

echo -e "VPS vnStat Telegram 流量日报脚本 $VERSION\n"

if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

# ---------------- 安装依赖 ----------------
install_dependencies() {
    info "开始检查并安装依赖: vnstat, jq, curl, bc..."

    # 检查并安装 vnstat
    if ! command -v vnstat &>/dev/null; then
        info "vnstat 未安装，开始安装..."
        if [ -f /etc/debian_version ]; then
            info "使用 IPv4 更新 apt 源..."
            for i in {1..3}; do
                if apt-get -o Acquire::ForceIPv4=true update -y; then break; else
                    warn "更新源失败，第 $i 次尝试..."
                    sleep 2
                fi
            done
            DEBIAN_FRONTEND=noninteractive apt-get install -y -o Acquire::ForceIPv4=true vnstat || {
                err "安装 vnstat 失败，请检查源地址"
                exit 1
            }
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache vnstat
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            if command -v dnf &>/dev/null; then
                dnf install -y vnstat
            else
                yum install -y epel-release
                yum install -y vnstat
            fi
        else
            warn "未识别系统，请确保已安装 vnstat"
        fi
    else
        info "vnstat 已安装，跳过安装"
    fi

    # 检查并安装 jq
    if ! command -v jq &>/dev/null; then
        info "jq 未安装，开始安装..."
        if [ -f /etc/debian_version ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y jq || {
                err "安装 jq 失败，请检查源地址"
                exit 1
            }
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache jq
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            if command -v dnf &>/dev/null; then
                dnf install -y jq
            else
                yum install -y jq
            fi
        else
            warn "未识别系统，请确保已安装 jq"
        fi
    else
        info "jq 已安装，跳过安装"
    fi

    # 检查并安装 curl
    if ! command -v curl &>/dev/null; then
        info "curl 未安装，开始安装..."
        if [ -f /etc/debian_version ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl || {
                err "安装 curl 失败，请检查源地址"
                exit 1
            }
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache curl
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            if command -v dnf &>/dev/null; then
                dnf install -y curl
            else
                yum install -y curl
            fi
        else
            warn "未识别系统，请确保已安装 curl"
        fi
    else
        info "curl 已安装，跳过安装"
    fi

    # 检查并安装 bc
    if ! command -v bc &>/dev/null; then
        info "bc 未安装，开始安装..."
        if [ -f /etc/debian_version ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y bc || {
                err "安装 bc 失败，请检查源地址"
                exit 1
            }
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache bc
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            if command -v dnf &>/dev/null; then
                dnf install -y bc
            else
                yum install -y bc
            fi
        else
            warn "未识别系统，请确保已安装 bc"
        fi
    else
        info "bc 已安装，跳过安装"
    fi

    info "依赖检查完成。"
}

# ---------------- 生成配置 ----------------
generate_config() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    # 保留原配置，升级用
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

    # 主机名手动输入（首次输入保存）
    if [ -z "${HOSTNAME_CUSTOM:-}" ]; then
        read -rp "请输入主机名 (默认 $(hostname)): " input
        HOSTNAME_CUSTOM=${input:-$(hostname)}
    fi

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
DEBUG_LOG="/tmp/vps_vnstat_debug.log"

debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$DEBUG_LOG"
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
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
KIB_TO_BYTES=$(( VNSTAT_VERSION >= 2 ? 1 : 1024 ))

# JSON路径判断
if echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length>0' &>/dev/null; then
    TRAFFIC_PATH="day"
elif echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.days // [] | length>0' &>/dev/null; then
    TRAFFIC_PATH="days"
else
    TRAFFIC_PATH="day"
fi

# ---------- 按 RESET_DAY 滚动周期 ----------
TODAY_DAY=$(date +%d)
TODAY_YM=$(date +%Y-%m)
if [ "$TODAY_DAY" -ge "$RESET_DAY" ]; then
    CYCLE_START="${TODAY_YM}-$(printf '%02d' "$RESET_DAY")"
else
    CYCLE_START="$(date -d "$TODAY_YM-01 -1 month" +%Y-%m)-$(printf '%02d' "$RESET_DAY")"
fi
CYCLE_END=$(date -d "$CYCLE_START +1 month -1 day" +%Y-%m-%d)

# 当前总流量
CUR_SUM_UNIT=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | (.rx+.tx)]|add//0")
CUR_SUM=$(echo "$CUR_SUM_UNIT*$KIB_TO_BYTES" | bc)

# 如果 state 文件不存在或周期改变则重置快照
if [ ! -f "$STATE_FILE" ] || [ "$(jq -r '.cycle_start' "$STATE_FILE")" != "$CYCLE_START" ]; then
    echo "{\"cycle_start\":\"$CYCLE_START\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
fi

SNAP_BYTES=$(jq -r '.snapshot_bytes' "$STATE_FILE")
USED_BYTES=$(echo "$CUR_SUM-$SNAP_BYTES"|bc)
[ "$(echo "$USED_BYTES<0"|bc)" -eq 1 ] && USED_BYTES=0
SNAP_DATE=$CYCLE_START

# ---------- 昨日流量 ----------
TARGET_DATE=$(date -d "yesterday" +%Y-%m-%d)
Y=$(date -d "$TARGET_DATE" +%Y)
M=$((10#$(date -d "$TARGET_DATE" +%m)))
D=$((10#$(date -d "$TARGET_DATE" +%d)))

read DAY_RX DAY_TX <<<$(echo "$VNSTAT_JSON" | jq -r \
    --argjson y "$Y" --argjson m "$M" --argjson d "$D" --arg p "$TRAFFIC_PATH" '
    (.interfaces[0].traffic[$p]//[])
    |map(select(.date.year==$y and .date.month==$m and .date.day==$d))
    |if length>0 then "\(.[-1].rx) \(.[-1].tx)" else "0 0" end')

DAY_RX=$(echo "$DAY_RX*$KIB_TO_BYTES"|bc)
DAY_TX=$(echo "$DAY_TX*$KIB_TO_BYTES"|bc)
DAY_TOTAL=$(echo "$DAY_RX+$DAY_TX"|bc)

# ---------- 进度条 ----------
BAR=""
for i in {1..10}; do
    if [ "$PERCENT" -ge $((i*10)) ]; then 
        BAR+="🟩"
    else 
        BAR+="⬜️"
    fi
done

MSG="📊 VPS 流量日报

🖥 主机：$HOST
🌐 地址：$IP
💾 网卡：$IFACE
⏰ 时间：$(date '+%Y-%m-%d %H:%M:%S')

📆 昨日流量 ($TARGET_DATE)
⬇️ $(format_bytes $DAY_RX)
⬆️ $(format_bytes $DAY_TX)
↕️ $(format_bytes $DAY_TOTAL)

📅 本周期流量
🔄 周期：$CYCLE_START ～ $CYCLE_END
⏳ 已用：$(format_bytes $USED_BYTES)
⏳ 剩余：$(format_bytes $REMAIN_BYTES)
⌛ 总量：$(format_bytes $MONTH_LIMIT_BYTES)

🎯 进度：$BAR $PERCENT%"

if [ "$MONTH_LIMIT_BYTES" -gt 0 ]; then
    REMAIN_PERCENT=$((100-PERCENT))
    if [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
        MSG="$MSG
⚠️ 流量告警：剩余 $REMAIN_PERCENT%"
    fi
fi

curl -s -X POST "$TG_API" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$MSG" >/dev/null
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新 v$VERSION"
}

# ---------------- systemd timer ----------------
generate_systemd() {
    source "$CONFIG_FILE" || { err "无法加载配置"; exit 1; }

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

# ---------------- 卸载 ----------------
uninstall_all() {
    info "开始卸载 vps_vnstat_telegram..."
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    rm -f "/tmp/vps_vnstat_debug.log"
    systemctl daemon-reload
    info "卸载完成。"
}

# ---------------- 主菜单 ----------------
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 $VERSION ---"
    echo "请选择操作："
    echo "1) 安装 (配置并安装)"
    echo "2) 升级 (更新脚本和服务，不修改配置)"
    echo "3) 卸载 (删除所有文件和定时任务)"
    echo "4) 退出"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            generate_systemd
            info "安装完成，定时任务已启用"
            info "查询指定日期流量：/usr/local/bin/vps_vnstat_telegram.sh YYYY-MM-DD"
            ;;
        2)
            generate_main_script
            generate_systemd
            info "升级完成，定时任务已启用"
            ;;
        3)
            uninstall_all
            ;;
        4)
            info "操作已取消"
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

main
