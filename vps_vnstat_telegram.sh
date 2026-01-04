#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.2.3 (含完整环境安装)
# =================================================================

VERSION="v1.2.3"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# --- 核心推送逻辑生成函数 (修复转义Bug) ---
generate_report_logic() {
cat <<'EOF' > $BIN_PATH
#!/bin/bash
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)

get_valid_date() {
    local target_year_month=$1; local target_day=$2
    local last_day=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    if [ "$target_day" -gt "$last_day" ]; then
        echo "${target_year_month}-${last_day}"
    else
        echo "${target_year_month}-$(printf "%02d" $target_day)"
    fi
}

CURRENT_DAY=$(date +%e | tr -d ' ')
CURRENT_YM=$(date +%Y-%m); LAST_YM=$(date -d "last month" +%Y-%m); NEXT_YM=$(date -d "next month" +%Y-%m)

if [ "$CURRENT_DAY" -ge "$RESET_DAY" ]; then
    START_DATE=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$NEXT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
else
    START_DATE=$(get_valid_date "$LAST_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$CURRENT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
fi

DATA_YEST=$(vnstat -i $INTERFACE --oneline 2>/dev/null)
if [ -z "$DATA_YEST" ]; then
    RX_YEST="n/a"; TX_YEST="n/a"; TOTAL_YEST="无数据"
else
    RX_YEST=$(echo $DATA_YEST | cut -d';' -f4)
    TX_YEST=$(echo $DATA_YEST | cut -d';' -f5)
    TOTAL_YEST=$(echo $DATA_YEST | cut -d';' -f6)
fi

if (( $(echo "$VNSTAT_VER >= 2.0" | bc -l) )); then
    PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
    PERIOD_TOTAL=$(echo $PERIOD_DATA | cut -d';' -f11)
else
    PERIOD_TOTAL=$(echo $DATA_YEST | cut -d';' -f11)
fi

format_to_gb() {
    local val=$1; local unit=$2
    case $unit in
        "TiB") echo "$val * 1024" | bc ;;
        "MiB") echo "$val / 1024" | bc -l ;;
        *) echo "$val" ;;
    esac
}
RAW_VAL=$(echo $PERIOD_TOTAL | awk '{print $1}'); RAW_UNIT=$(echo $PERIOD_TOTAL | awk '{print $2}')
USED_GB=$(format_to_gb "$RAW_VAL" "$RAW_UNIT")

gen_bar() {
    local used=$1; local max=$2; local len=10
    local pct=$(echo "$used * 100 / $max" | bc 2>/dev/null)
    [ -z "$pct" ] && pct=0; (( pct > 100 )) && pct=100
    local char="🟩"; [ "$pct" -ge 50 ] && char="🟧"; [ "$pct" -ge 80 ] && char="🟥"
    local fill=$(echo "$pct * $len / 100" | bc); local bar=""
    for ((i=0; i<fill; i++)); do bar+="$char"; done; for ((i=fill; i<len; i++)); do bar+="⬜"; done
    echo "$bar ${pct%.*}%"
}
BAR_STR=$(gen_bar "$USED_GB" "$MAX_GB")

MSG="📊 *流量日报 | $HOST_ALIAS*

📅 统计周期: \`$START_DATE\` 至 \`$END_DATE\`
🌐 监控网卡: $INTERFACE

📥 昨日下载: $RX_YEST
📤 昨日上传: $TX_YEST
✨ 昨日合计: $TOTAL_YEST

📈 周期累计: $PERIOD_TOTAL
📊 限额进度:
$BAR_STR ($MAX_GB GB)"

curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 辅助功能：Cron 管理 ---
manage_cron() {
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
}

# --- 核心功能：环境安装 ---
install_env() {
    echo "正在检测系统环境并安装必要组件..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y vnstat curl bc cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y vnstat curl bc cronie
    else
        echo "❌ 暂不支持的系统类型。"
        exit 1
    fi
    
    # 启动并启用 vnStat
    systemctl enable vnstat --now
    # 启动并启用 Cron
    systemctl enable cron || systemctl enable crond
    systemctl start cron || systemctl start crond
    
    echo "✅ 环境组件安装完成。"
}

# --- 核心功能：主安装逻辑 ---
install_all() {
    install_env
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ">>> 首次安装，开始配置参数..."
        # 智能识别默认网卡
        DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr' | head -n1)
        
        read -p "👤 主机别名: " HOST_ALIAS
        read -p "🤖 TG Bot Token: " TG_TOKEN
        read -p "🆔 TG Chat ID: " TG_CHAT_ID
        read -p "📅 重置日 (1-31): " RESET_DAY
        read -p "📊 流量限额 (GB): " MAX_GB
        
        cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$DEFAULT_IFACE"
EOF
        # 初始化网卡数据库
        vnstat -u -i "$DEFAULT_IFACE" >/dev/null 2>&1
    fi
    
    generate_report_logic
    manage_cron
    echo "✅ 全部安装配置成功 ($VERSION)！"
}

# --- 菜单界面 ---
clear
echo "=============================="
echo "  流量统计管理工具 $VERSION"
echo "=============================="
echo "1. 安装完整环境并配置"
echo "2. 升级推送逻辑 (修复/更新)"
echo "3. 卸载推送项目"
echo "4. 手动发送测试日报"
echo "5. 退出"
echo "------------------------------"
read -p "请选择操作 [1-5]: " choice

case $choice in
    1) install_all ;;
    2) generate_report_logic && manage_cron && echo "✅ 升级成功。" ;;
    3) crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab - && rm -f $BIN_PATH && echo "✅ 卸载完成。" ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试消息已发出" || echo "❌ 尚未安装，请选1" ;;
    5) exit ;;
esac
