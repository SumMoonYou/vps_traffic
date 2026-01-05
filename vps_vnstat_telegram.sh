#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.3.2
# 描述: 基于 vnStat 的流量监控脚本，支持 TG 自动日报。
# =================================================================

VERSION="v1.3.2"
CONFIG_FILE="/etc/vnstat_tg.conf"          # 核心配置文件
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh" # 后台推送脚本

# --- 核心函数：生成执行脚本 ---
# 说明：此函数生成的脚本将被 Cron 定时调用
generate_report_logic() {
cat <<'EOF' > $BIN_PATH
#!/bin/bash
# 导入持久化配置
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

# 获取环境信息
VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)
# 强制获取 IPv4 地址
SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api64.ipify.org || curl -4 -s --connect-timeout 5 ifconfig.me || curl -s https://api64.ipify.org || curl -s ifconfig.me)

# --- 函数：强制单位缩写 (将 vnStat 的 GiB 改为 GB) ---
simplify_unit() {
    # 使用 sed 批量替换二进制单位为常用简写单位
    echo "$1" | sed 's/GiB/GB/g; s/MiB/MB/g; s/KiB/KB/g; s/TiB/TB/g'
}

# --- 函数：日期对齐 (补零并处理月末) ---
get_valid_date() {
    local target_year_month=$1; local target_day=$2
    # 获取目标月最后一天
    local last_day_num=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    if [ "$target_day" -gt "$last_day_num" ]; then
        echo "${target_year_month}-$(printf "%02d" $last_day_num)"
    else
        echo "${target_year_month}-$(printf "%02d" $target_day)"
    fi
}

# --- 逻辑：计算统计周期 ---
CURRENT_DAY_NUM=$(date +%d | sed 's/^0//') # 获取今日号数(去前导0)
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

# --- 逻辑：采集流量数据 ---
DATA_YEST=$(vnstat -i $INTERFACE --oneline 2>/dev/null)
if [ -z "$DATA_YEST" ]; then
    RX_YEST="n/a"; TX_YEST="n/a"; TOTAL_YEST="n/a"
else
    # 提取第 4,5,6 列并精简单位
    RX_YEST=$(simplify_unit "$(echo $DATA_YEST | cut -d';' -f4)")
    TX_YEST=$(simplify_unit "$(echo $DATA_YEST | cut -d';' -f5)")
    TOTAL_YEST=$(simplify_unit "$(echo $DATA_YEST | cut -d';' -f6)")
fi

# 采集周期累计流量 (vnstat 2.x 支持 --begin 参数)
if (( $(echo "$VNSTAT_VER >= 2.0" | bc -l) )); then
    PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
    PERIOD_TOTAL=$(simplify_unit "$(echo $PERIOD_DATA | cut -d';' -f11)")
else
    PERIOD_TOTAL=$(simplify_unit "$(echo $DATA_YEST | cut -d';' -f11)")
fi

# --- 逻辑：计算进度条 ---
format_to_gb() {
    local val=$1; local unit=$2
    case $unit in
        "TiB"|"TB") echo "$val * 1024" | bc ;;
        "MiB"|"MB") echo "$val / 1024" | bc -l ;;
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
SEND_TIME=$(date "+%Y-%m-%d %H:%M")

# --- 构造推送消息 ---
MSG="📊 *流量日报 | $HOST_ALIAS*

🛜 地址：\`$SERVER_IP\`
📥 下载：$RX_YEST
📤 上传：$TX_YEST
🈴 合计：$TOTAL_YEST
🕙 时间：$SEND_TIME

📈 累计：$PERIOD_TOTAL
📅 周期：$START_DATE 至 $END_DATE
🎯 进度：$BAR_STR ($MAX_GB GB)"

# 发送至 Telegram
curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=$MSG" \
    -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 函数：环境安装与初始配置 ---
install_all() {
    echo ">>> 正在自动安装环境依赖..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq vnstat curl bc cron >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q epel-release && yum install -y -q vnstat curl bc cronie >/dev/null 2>&1
    fi
    systemctl enable vnstat --now
    systemctl enable cron || systemctl enable crond
    systemctl start cron || systemctl start crond

    echo ">>> 开始录入配置 (将直接覆盖旧配置):"
    # 自动识别主网卡
    DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr' | head -n1)
    
    read -p "👤 主机别名: " HOST_ALIAS
    read -p "🤖 TG Bot Token: " TG_TOKEN
    read -p "🆔 TG Chat ID: " TG_CHAT_ID
    read -p "📅 每月重置日 (1-31): " RESET_DAY
    read -p "📊 流量限额 (GB): " MAX_GB
    
    # 持久化存储
    cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$DEFAULT_IFACE"
EOF
    # 初始化 vnstat 数据库
    vnstat -u -i "$DEFAULT_IFACE" >/dev/null 2>&1
    
    # 生成推送逻辑并写入定时任务 (凌晨 1:00)
    generate_report_logic
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
    
    echo "✅ 完整安装与配置已完成 ($VERSION)！"
}

# --- 菜单导航 ---
clear
echo "==========================================="
echo "   流量统计 TG 管理工具 $VERSION"
echo "==========================================="
echo " 1. 安装"
echo " 2. 升级"
echo " 3. 卸载"
echo " 4. 立即手动执行 (发送测试日报)"
echo " 5. 退出"
echo "-------------------------------------------"
read -p "请选择操作 [1-5]: " choice

case $choice in
    1) install_all ;;
    2) generate_report_logic && echo "✅ 已升级" ;;
    3) crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab - && rm -f $BIN_PATH $CONFIG_FILE && echo "✅ 已彻底清理。" ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试日报已发出。" || echo "❌ 尚未安装。" ;;
    5) exit ;;
esac
