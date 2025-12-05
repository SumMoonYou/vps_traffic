#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本（含升级功能）
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"
UPGRADE_FILE="/usr/local/bin/vps_vnstat_telegram_upgrade.sh"

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

# 生成主脚本 (兼容版)
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh (兼容版：修复所有已知问题)
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
        echo "{\"last_snapshot_date\":\"$(date +%Y-%m-%d)\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
    fi

    # 获取并格式化流量数据
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

    # Telegram 通知消息
    MSG="📊 VPS 流量日报

🖥 主机：$HOSTNAME
🌐 地址：$IP
💾 网卡：$IFACE
⏰ 时间：$(date '+%Y-%m-%d %H:%M:%S')

📅 昨日流量 ($TARGET_DATE_STR)
⬇️ 下载：$(format_bytes $DAY_RX)
⬆️ 上传：$(format_bytes $DAY_TX)
↕️ 总计：$(format_bytes $DAY_TOTAL)"

    curl -s -X POST "$TG_API" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MSG" >/dev/null 2>&1
fi

EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新，修复了所有已知的兼容性问题，并提高了鲁棒性。"
}

# 升级脚本
upgrade_script() {
    info "正在升级 vps_vnstat_telegram 脚本..."
    mv "$SCRIPT_FILE" "$SCRIPT_FILE.bak"
    install_dependencies
    generate_config
    generate_main_script
    info "脚本升级完成，保留了配置文件和状态数据。"
}

# 主菜单
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 (兼容版) ---"
    echo "请选择操作："
    echo "1) 安装 (自动安装依赖、配置、设置定时任务)"
    echo "2) 升级 (保留配置文件，更新脚本)"
    echo "3) 卸载 (删除所有文件和定时任务)"
    echo "4) 退出"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            ;;
        2)
            upgrade_script
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
