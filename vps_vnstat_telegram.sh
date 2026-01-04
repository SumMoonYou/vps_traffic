#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.2.4
# 描述: 自动安装 vnStat 环境，并通过 Telegram Bot 发送每日流量日报。
# 特色: 自动对齐月末日期、彩色进度条显示、无损升级逻辑。
# =================================================================

VERSION="v1.2.4"
CONFIG_FILE="/etc/vnstat_tg.conf"          # 存储用户配置的文件
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh" # 实际执行推送的任务脚本

# --- 函数：生成推送脚本的核心逻辑 ---
generate_report_logic() {
# 使用 'EOF' 确保脚本内的变量 $ 在写入文件前不被当前 shell 解析
cat <<'EOF' > $BIN_PATH
#!/bin/bash
# 从配置文件中读取变量：HOST_ALIAS, TG_TOKEN, TG_CHAT_ID, RESET_DAY, MAX_GB, INTERFACE
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

# 获取 vnStat 版本号（适配 1.x 和 2.x 版本的指令差异）
VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)

# --- 内部函数：处理重置日不存在的情况（如 2月无30号） ---
get_valid_date() {
    local target_year_month=$1 # 格式 YYYY-MM
    local target_day=$2        # 用户设定的重置日
    # 计算目标月份实际的最后一天
    local last_day=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    # 如果重置日超过了该月最大天数，则使用该月最后一天
    if [ "$target_day" -gt "$last_day" ]; then
        echo "${target_year_month}-${last_day}"
    else
        echo "${target_year_month}-$(printf "%02d" $target_day)"
    fi
}

# --- 步骤 1：确定当前处于哪个结算周期 ---
CURRENT_DAY=$(date +%e | tr -d ' ')   # 今日是几号
CURRENT_YM=$(date +%Y-%m)            # 本月 YYYY-MM
LAST_YM=$(date -d "last month" +%Y-%m) # 上月 YYYY-MM
NEXT_YM=$(date -d "next month" +%Y-%m) # 下月 YYYY-MM

if [ "$CURRENT_DAY" -ge "$RESET_DAY" ]; then
    # 如果今日已达到或超过重置日：周期为 [本月重置日] 至 [下月重置日前一天]
    START_DATE=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$NEXT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
else
    # 如果今日未到重置日：周期为 [上月重置日] 至 [本月重置日前一天]
    START_DATE=$(get_valid_date "$LAST_YM" "$RESET_DAY")
    END_DATE=$(date -d "$(get_valid_date "$CURRENT_YM" "$RESET_DAY") -1 day" +%Y-%m-%d)
fi

# --- 步骤 2：通过 vnstat 采集流量数据 ---
# --oneline 模式数据索引: 3=RX(下行), 4=TX(上行), 5=Total(昨日合计)
DATA_YEST=$(vnstat -i $INTERFACE --oneline 2>/dev/null)
if [ -z "$DATA_YEST" ]; then
    RX_YEST="n/a"; TX_YEST="n/a"; TOTAL_YEST="无数据"
else
    RX_YEST=$(echo $DATA_YEST | cut -d';' -f4)
    TX_YEST=$(echo $DATA_YEST | cut -d';' -f5)
    TOTAL_YEST=$(echo $DATA_YEST | cut -d';' -f6)
fi

# 获取周期内的累计流量
if (( $(echo "$VNSTAT_VER >= 2.0" | bc -l) )); then
    PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
    PERIOD_TOTAL=$(echo $PERIOD_DATA | cut -d';' -f11)
else
    # vnstat 1.x 版本不支持 --begin 参数，默认展示库内全部累计
    PERIOD_TOTAL=$(echo $DATA_YEST | cut -d';' -f11)
fi

# --- 步骤 3：换算流量为 GB 并生成进度条 ---
format_to_gb() {
    local val=$1; local unit=$2
    case $unit in
        "TiB") echo "$val * 1024" | bc ;;
        "MiB") echo "$val / 1024" | bc -l ;;
        *) echo "$val" ;;
    esac
}
RAW_VAL=$(echo $PERIOD_TOTAL | awk '{print $1}')
RAW_UNIT=$(echo $PERIOD_TOTAL | awk '{print $2}')
USED_GB=$(format_to_gb "$RAW_VAL" "$RAW_UNIT")

gen_bar() {
    local used=$1; local max=$2; local len=10
    local pct=$(echo "$used * 100 / $max" | bc 2>/dev/null)
    [ -z "$pct" ] && pct=0; (( pct > 100 )) && pct=100
    
    # 动态颜色：<50% 绿色，50-80% 橙色，>80% 红色
    local char="🟩"; [ "$pct" -ge 50 ] && char="🟧"; [ "$pct" -ge 80 ] && char="🟥"
    local fill=$(echo "$pct * $len / 100" | bc)
    local bar=""
    for ((i=0; i<fill; i++)); do bar+="$char"; done
    for ((i=fill; i<len; i++)); do bar+="⬜"; done
    echo "$bar ${pct%.*}%"
}
BAR_STR=$(gen_bar "$USED_GB" "$MAX_GB")

# --- 步骤 4：推送 Telegram 消息 ---
MSG="📊 *流量日报 | $HOST_ALIAS*

📅 统计周期: \`$START_DATE\` 至 \`$END_DATE\`
🌐 监控网卡: $INTERFACE

📥 昨日下载: $RX_YEST
📤 昨日上传: $TX_YEST
✨ 昨日合计: $TOTAL_YEST

📈 周期累计: $PERIOD_TOTAL
📊 限额进度:
$BAR_STR ($MAX_GB GB)"

curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=$MSG" \
    -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 函数：管理 Crontab 定时任务（防止重复添加） ---
manage_cron() {
    # 逻辑：列出所有任务 -> 过滤掉本项目相关任务 -> 重新写入并添加新任务 (凌晨 1:00 执行)
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
}

# --- 函数：安装系统环境依赖 ---
install_env() {
    echo ">>> 正在检测并安装依赖 (vnstat, curl, bc, cron)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y vnstat curl bc cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y vnstat curl bc cronie
    else
        echo "❌ 不支持的操作系统。" && exit 1
    fi
    systemctl enable vnstat --now
    systemctl enable cron || systemctl enable crond
    systemctl start cron || systemctl start crond
}

# --- 函数：主安装与交互流程 ---
install_all() {
    install_env
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ">>> 开始配置个性化参数..."
        # 自动获取默认路由网卡
        DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr' | head -n1)
        
        read -p "👤 主机别名 (如: 香港A区): " HOST_ALIAS
        read -p "🤖 TG Bot Token: " TG_TOKEN
        read -p "🆔 TG Chat ID: " TG_CHAT_ID
        read -p "📅 重置日 (1-31): " RESET_DAY
        read -p "📊 流量限额 (单位GB): " MAX_GB
        
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
    echo "✅ 全部操作已完成！"
}

# --- 交互菜单 ---
clear
echo "==========================================="
echo "   流量统计 TG 推送管理工具 $VERSION"
echo "==========================================="
echo " 1. 安装/重新配置 (适合新服务器)"
echo " 2. 升级逻辑 (保留原有配置，仅更新功能)"
echo " 3. 卸载项目 (清理脚本与定时任务)"
echo " 4. 立即手动执行 (测试推送效果)"
echo " 5. 退出"
echo "-------------------------------------------"
read -p "请输入选项 [1-5]: " choice

case $choice in
    1) install_all ;;
    2) generate_report_logic && manage_cron && echo "✅ 逻辑已更新至 $VERSION" ;;
    3) crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab - && rm -f $BIN_PATH && echo "✅ 已卸载任务" ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试日报已发送" || echo "❌ 尚未安装" ;;
    5) exit ;;
esac
