#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.5.6
# =================================================================

VERSION="v1.5.6"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

generate_report_logic() {
cat <<'EOF' > $BIN_PATH
#!/bin/bash
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1
VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)

# 强制获取 IPv4 地址
SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api64.ipify.org || curl -4 -s --connect-timeout 5 ifconfig.me || echo "IPv4获取失败")

simplify_unit() {
    echo "$1" | sed 's/GiB/GB/g; s/MiB/MB/g; s/KiB/KB/g; s/TiB/TB/g'
}

get_valid_date() {
    local target_year_month=$1; local target_day=$2
    local last_day_num=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    [ "$target_day" -gt "$last_day_num" ] && echo "${target_year_month}-$(printf "%02d" $last_day_num)" || echo "${target_year_month}-$(printf "%02d" $target_day)"
}

# 周期计算
CURRENT_DAY_NUM=$(date +%d | sed 's/^0//')
CURRENT_YM=$(date +%Y-%m); LAST_YM=$(date -d "last month" +%Y-%m); NEXT_YM=$(date -d "next month" +%Y-%m)

if [ "$CURRENT_DAY_NUM" -ge "$RESET_DAY" ]; then
    START_DATE=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    NEXT_RESET=$(get_valid_date "$NEXT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$NEXT_RESET -1 day" +%Y-%m-%d)
else
    START_DATE=$(get_valid_date "$LAST_YM" "$RESET_DAY")
    THIS_RESET=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$THIS_RESET -1 day" +%Y-%m-%d)
fi

# 采集并过滤明细表 (显示本周期内所有天数)
DAILY_DETAILS=""
IFS=$'\n'
# 获取最近 31 天记录并按日期正序排列
for line in $(vnstat -i $INTERFACE -d --limit 31 --oneline | grep -E "^[0-9]" | sort -t';' -k2); do
    D_DATE=$(echo $line | cut -d';' -f2)
    # 核心过滤：只保留 [本周期开始日期] 之后的数据
    if [[ "$D_DATE" < "$START_DATE" ]]; then continue; fi
    
    D_RX=$(simplify_unit "$(echo $line | cut -d';' -f3)")
    D_TX=$(simplify_unit "$(echo $line | cut -d';' -f4)")
    D_TOTAL=$(simplify_unit "$(echo $line | cut -d';' -f5)")
    DAILY_DETAILS+="$(printf "%-10s %-7s %-7s %-7s" "$D_DATE" "$D_RX" "$D_TX" "$D_TOTAL")\n"
done

# 周期累计
PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
P_RX=$(simplify_unit "$(echo $PERIOD_DATA | cut -d';' -f9)")
P_TX=$(simplify_unit "$(echo $PERIOD_DATA | cut -d';' -f10)")
P_TOTAL=$(simplify_unit "$(echo $PERIOD_DATA | cut -d';' -f11)")

# 进度条
format_to_gb() {
    local val=$1; local unit=$2
    case $unit in "TiB"|"TB") echo "$val * 1024" | bc ;; "MiB"|"MB") echo "$val / 1024" | bc -l ;; *) echo "$val" ;; esac
}
RAW_VAL=$(echo $P_TOTAL | awk '{print $1}'); RAW_UNIT=$(echo $P_TOTAL | awk '{print $2}')
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
SEND_TIME=$(date "+%Y-%m-%d %H:%M")

# --- 消息构造 ---
MSG="📊 *流量日报 | $HOST_ALIAS*

🛜 地址：\`$SERVER_IP\`
🕙 时间：$SEND_TIME

📅 *本周期每日明细 (Date | RX | TX | Total):*
\`\`\`text
$(printf "%-10s %-7s %-7s %-7s" "Date" "RX" "TX" "Total")
------------------------------------
$DAILY_DETAILS\`\`\`
📈 *周期统计汇总:*
📥 总下载：$P_RX
📤 总上传：$P_TX
🈴 总合计：$P_TOTAL
📅 周期：$START_DATE 至 $END_DATE
🎯 进度：$BAR_STR ($MAX_GB GB)"

curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

install_all() {
    echo "正在安装依赖..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq vnstat curl bc cron >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q epel-release && yum install -y -q vnstat curl bc cronie >/dev/null 2>&1
    fi
    systemctl enable vnstat --now
    echo ">>> 请输入配置参数:"
    DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
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
    generate_report_logic
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
    echo "✅ 安装成功！"
}

# 菜单
clear
echo "=============================="
echo "  流量统计管理工具 $VERSION"
echo "=============================="
echo "1. 安装 / 重新配置 (强制覆盖)"
echo "2. 升级逻辑"
echo "3. 卸载项目"
echo "4. 手动发送测试日报"
echo "5. 退出"
echo "------------------------------"
read -p "请选择操作 [1-5]: " choice
case $choice in
    1) install_all ;;
    2) generate_report_logic && echo "✅ 逻辑已升级。" ;;
    3) crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab - && rm -f $BIN_PATH $CONFIG_FILE && echo "✅ 已彻底卸载。" ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试已发送。" || echo "❌ 未安装。" ;;
    5) exit ;;
esac
