#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具 (整合版)
# 功能: 自动安装、智能日期处理、进度条、明细显示、无损升级
# 更新时间: 2026-01-05
# =================================================================

CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# --- 核心逻辑：推送脚本内容 ---
generate_report_logic() {
cat <<'EOF' > $BIN_PATH
#!/bin/bash
# 加载持久化配置
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

# 检测 vnstat 版本以适配不同指令
VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)

# --- 函数：计算有效的结算日期（处理 2月/小月没有31号的情况） ---
get_valid_date() {
    local target_year_month=$1; local target_day=$2
    local last_day=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    if [ "$target_day" -gt "$last_day" ]; then
        echo "${target_year_month}-${last_day}"
    else
        echo "${target_year_month}-$(printf "%02d" $target_day)"
    fi
}

# --- 计算当前结算周期 (Start/End) ---
CURRENT_DAY=$(date +%e | tr -d ' ')
CURRENT_YM=$(date +%Y-%m); LAST_YM=$(date -d "last month" +%Y-%m); NEXT_YM=$(date -d "next month" +%Y-%m)

if [ "$CURRENT_DAY" -ge "$RESET_DAY" ]; then
    START_DATE=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$NEXT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
else
    START_DATE=$(get_valid_date "$LAST_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$CURRENT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
fi

# --- 采集昨日数据 ---
DATA_YEST=$(vnstat -i $INTERFACE --oneline 2>/dev/null)
if [ -z "$DATA_YEST" ]; then
    RX_YEST="n/a"; TX_YEST="n/a"; TOTAL_YEST="无数据"
else
    # 索引: 3=下载, 4=上传, 5=总计
    RX_YEST=$(echo $DATA_YEST | cut -d';' -f4)
    TX_YEST=$(echo $DATA_YEST | cut -d';' -f5)
    TOTAL_YEST=$(echo $DATA_YEST | cut -d';' -f6)
fi

# --- 采集周期累计数据 ---
if (( $(echo "$VNSTAT_VER >= 2.0" | bc -l) )); then
    PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
    PERIOD_TOTAL=$(echo $PERIOD_DATA | cut -d';' -f11)
else
    # 旧版降级处理
    PERIOD_TOTAL=$(echo $DATA_YEST | cut -d';' -f11)
fi

# --- 流量换算与进度条 ---
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
    local fill=$(echo "$pct * $len / 100" | bc); local empty=$((len - fill))
    local bar=""; for ((i=0; i<fill; i++)); do bar+="■"; done
    for ((i=0; i<empty; i++)); do bar+="□"; done
    echo "[$bar] ${pct%.*}%"
}
BAR_STR=$(gen_bar "$USED_GB" "$MAX_GB")

# --- 构建消息并发送 ---
MSG="📊 *流量日报 | $HOST_ALIAS*

📅 统计周期: \`$START_DATE\` 至 \`$END_DATE\`
🌐 监控网卡: $INTERFACE

📥 昨日下载: $RX_YEST
📤 昨日上传: $TX_YEST
✨ 昨日合计: $TOTAL_YEST

📈 周期累计: $PERIOD_TOTAL
📊 限额进度:
\`$BAR_STR\` ($MAX_GB GB)

🚀 _Status: Monitoring Active_"

curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=$MSG" \
    -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 功能：管理定时任务 (防止重复) ---
manage_cron() {
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
}

# --- 功能：安装 ---
install_all() {
    echo "正在安装依赖组件 (vnstat, curl, bc)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq vnstat curl bc cron >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q epel-release && yum install -y -q vnstat curl bc cronie >/dev/null 2>&1
    fi
    systemctl enable vnstat --now >/dev/null 2>&1

    if [ ! -f "$CONFIG_FILE" ]; then
        echo ">>> 首次安装，请设置参数"
        DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr' | head -n1)

        read -p "👤 主机别名: " HOST_ALIAS
        read -p "🤖 TG Bot Token: " TG_TOKEN
        read -p "🆔 TG Chat ID: " TG_CHAT_ID
        read -p "📅 每月重置日 (1-31): " RESET_DAY
        read -p "📊 流量限额 (GB): " MAX_GB
        
        cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$DEFAULT_IFACE"
EOF
        vnstat -u -i "$DEFAULT_IFACE" >/dev/null 2>&1
    fi
    generate_report_logic
    manage_cron
    echo "✅ 安装及定时任务配置成功！"
}

# --- 功能：升级 ---
upgrade_script() {
    echo "正在升级推送逻辑 (保留配置并更新 Cron)..."
    generate_report_logic
    manage_cron
    echo "✅ 逻辑升级完成。"
}

# --- 功能：卸载 ---
uninstall_all() {
    read -p "⚠️ 确认要删除推送脚本和定时任务吗？(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab -
        rm -f $BIN_PATH
        echo "✅ 卸载成功。配置文件 /etc/vnstat_tg.conf 已保留。"
    fi
}

# --- 菜单主界面 ---
clear
echo "=============================="
echo "  流量统计 TG 推送管理工具"
echo "=============================="
echo "1. 安装 / 重新配置"
echo "2. 升级逻辑 (不触动配置)"
echo "3. 卸载脚本"
echo "4. 立即手动发送测试"
echo "5. 退出"
echo "------------------------------"
read -p "请选择操作 [1-5]: " choice

case $choice in
    1) install_all ;;
    2) upgrade_script ;;
    3) uninstall_all ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试日报已发送" || echo "❌ 脚本尚未安装" ;;
    5) exit ;;
    *) echo "输入错误" ;;
esac

