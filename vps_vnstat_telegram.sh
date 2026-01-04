#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.2.6
# 描述: 自动安装 vnStat 环境，并通过 Telegram Bot 发送补零对齐格式的日报。
# =================================================================

VERSION="v1.2.6"
CONFIG_FILE="/etc/vnstat_tg.conf"          # 持久化配置文件路径
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh" # 实际执行推送的任务脚本

# --- 函数：生成推送脚本的核心逻辑 ---
generate_report_logic() {
# 使用 'EOF' (加单引号) 锁定内部所有变量，防止在写入文件时被当前 shell 解析
cat <<'EOF' > $BIN_PATH
#!/bin/bash
# 加载用户配置：包含别名、Token、ChatID、重置日、限额和网卡名
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

# 获取 vnStat 主版本号用于兼容性判断 (1.x 与 2.x 指令集不同)
VNSTAT_VER=$(vnstat --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)

# --- 内部函数：生成补零对齐的 YYYY-MM-DD 日期 ---
get_valid_date() {
    local target_year_month=$1 # 传入格式如 2026-01
    local target_day=$2        # 用户设定的重置日数字
    # 计算目标月份实际的最大天数 (解决大小月及平闰年问题)
    local last_day_num=$(date -d "${target_year_month}-01 +1 month -1 day" +%d)
    if [ "$target_day" -gt "$last_day_num" ]; then
        # 如果设定的重置日不存在（如2月31号），则自动回退到该月最后一天
        echo "${target_year_month}-$(printf "%02d" $last_day_num)"
    else
        # 使用 printf %02d 强制补零，如 2026-01-05
        echo "${target_year_month}-$(printf "%02d" $target_day)"
    fi
}

# --- 核心计算：确定统计周期的起止日期 ---
# CURRENT_DAY_NUM 取今日号数并去除前导0，用于逻辑大小比较
CURRENT_DAY_NUM=$(date +%d | sed 's/^0//')
CURRENT_YM=$(date +%Y-%m)
LAST_YM=$(date -d "last month" +%Y-%m)
NEXT_YM=$(date -d "next month" +%Y-%m)

if [ "$CURRENT_DAY_NUM" -ge "$RESET_DAY" ]; then
    # 情况 A：今日已到达或超过重置日。周期起始 = 本月重置日，结束 = 下月重置日前一天
    START_DATE=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    NEXT_RESET=$(get_valid_date "$NEXT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$NEXT_RESET -1 day" +%Y-%m-%d)
else
    # 情况 B：今日未到重置日。周期起始 = 上月重置日，结束 = 本月重置日前一天
    START_DATE=$(get_valid_date "$LAST_YM" "$RESET_DAY")
    THIS_RESET=$(get_valid_date "$CURRENT_YM" "$RESET_DAY")
    END_DATE=$(date -d "$THIS_RESET -1 day" +%Y-%m-%d)
fi

# --- 数据采集：昨日流量统计 ---
# 使用 vnstat --oneline 模式。字段索引: 4=昨日下载, 5=昨日上传, 6=昨日总计
DATA_YEST=$(vnstat -i $INTERFACE --oneline 2>/dev/null)
if [ -z "$DATA_YEST" ]; then
    RX_YEST="n/a"; TX_YEST="n/a"; TOTAL_YEST="无数据"
else
    RX_YEST=$(echo $DATA_YEST | cut -d';' -f4)
    TX_YEST=$(echo $DATA_YEST | cut -d';' -f5)
    TOTAL_YEST=$(echo $DATA_YEST | cut -d';' -f6)
fi

# --- 数据采集：结算周期累计流量 ---
if (( $(echo "$VNSTAT_VER >= 2.0" | bc -l) )); then
    # vnStat 2.0+ 支持 --begin 指定起始统计时间
    PERIOD_DATA=$(vnstat -i $INTERFACE --begin $START_DATE --oneline 2>/dev/null)
    PERIOD_TOTAL=$(echo $PERIOD_DATA | cut -d';' -f11)
else
    # vnStat 1.x 降级方案：展示库内全部累计数据
    PERIOD_TOTAL=$(echo $DATA_YEST | cut -d';' -f11)
fi

# --- 换算与彩色进度条 ---
# 统一将 TiB/MiB 转换为 GB 供百分比计算
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
    # 状态识别：绿色(<50%) -> 橙色(50-80%) -> 红色(>80%)
    local char="🟩"; [ "$pct" -ge 50 ] && char="🟧"; [ "$pct" -ge 80 ] && char="🟥"
    local fill=$(echo "$pct * $len / 100" | bc); local bar=""
    for ((i=0; i<fill; i++)); do bar+="$char"; done
    for ((i=fill; i<len; i++)); do bar+="⬜"; done
    echo "$bar ${pct%.*}%"
}
BAR_STR=$(gen_bar "$USED_GB" "$MAX_GB")

# --- 推送消息：构建 Markdown 内容 ---
MSG="📊 *流量日报 | $HOST_ALIAS*

📅 统计周期: \`$START_DATE\` 至 \`$END_DATE\`
🌐 监控网卡: $INTERFACE

📥 昨日下载: $RX_YEST
📤 昨日上传: $TX_YEST
🈴 昨日合计: $TOTAL_YEST

📈 周期累计: $PERIOD_TOTAL
📊 限额进度:
$BAR_STR ($MAX_GB GB)"

# 通过 Telegram Bot API 发送消息
curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=$MSG" \
    -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 函数：环境安装与 Crontab 管理 ---
manage_cron() {
    # 凌晨 01:00 执行推送任务，并确保 cron 列表不含重复条目
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "0 1 * * * $BIN_PATH") | crontab -
}

install_all() {
    echo ">>> 正在安装依赖 (vnstat, curl, bc, cron)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y vnstat curl bc cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y vnstat curl bc cronie
    fi
    systemctl enable vnstat --now
    systemctl enable cron || systemctl enable crond
    systemctl start cron || systemctl start crond

    if [ ! -f "$CONFIG_FILE" ]; then
        # 智能识别默认网卡 (排除 lo, docker, 虚拟网卡等)
        DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr' | head -n1)
        
        echo ">>> 请输入个性化配置:"
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
    echo "✅ 环境安装与逻辑配置已完成 ($VERSION)！"
}

# --- 菜单界面 ---
clear
echo "==========================================="
echo "   流量统计 TG 推送管理工具 $VERSION"
echo "==========================================="
echo " 1. 安装完整环境并配置 (适合新服务器)"
echo " 2. 升级"
echo " 3. 卸载"
echo " 4. 立即手动执行 (测试推送效果)"
echo " 5. 退出"
echo "-------------------------------------------"
read -p "请输入选项 [1-5]: " choice

case $choice in
    1) install_all ;;
    2) generate_report_logic && manage_cron && echo "✅ 升级完成，日期格式与 Emoji 已对齐。" ;;
    3) crontab -l 2>/dev/null | grep -v "$BIN_PATH" | crontab - && rm -f $BIN_PATH && echo "✅ 已彻底卸载推送任务。" ;;
    4) [ -f "$BIN_PATH" ] && $BIN_PATH && echo "✅ 测试日报已发出。" || echo "❌ 尚未安装，请选选项 1。" ;;
    5) exit ;;
esac
