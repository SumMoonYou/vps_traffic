#!/bin/bash

CONFIG_FILE="/etc/traffic_report_config.json"
SCRIPT_FILE="/usr/local/bin/traffic_report.sh"
TIMER_FILE="/etc/systemd/system/traffic_report.timer"
SERVICE_FILE="/etc/systemd/system/traffic_report.service"

# ------------------- 系统和依赖检查 -------------------
install_dependencies() {
    echo "正在检测并安装依赖环境..."
    if [ -f /etc/debian_version ]; then
        PKG_MANAGER="apt-get"
        sudo apt-get update -y
    elif [ -f /etc/redhat-release ]; then
        PKG_MANAGER="yum"
    elif [ -f /etc/alpine-release ]; then
        PKG_MANAGER="apk"
    else
        echo "不支持的系统类型！"
        exit 1
    fi

    for cmd in vnstat curl jq bc; do
        if ! command -v $cmd &>/dev/null; then
            echo "$cmd 未安装，正在安装..."
            case $PKG_MANAGER in
            apt-get)
                sudo apt-get install -y $cmd ;;
            yum)
                sudo yum install -y $cmd ;;
            apk)
                sudo apk add --no-cache $cmd ;;
            esac
        else
            echo "$cmd 已安装"
        fi
    done
}

# ------------------- 生成执行脚本 -------------------
generate_execution_script() {
    cat > $SCRIPT_FILE <<'EOL'
#!/bin/bash
CONFIG_FILE="/etc/traffic_report_config.json"
[ ! -f "$CONFIG_FILE" ] && echo "配置文件不存在！" && exit 1

CFG=$(cat $CONFIG_FILE)
MACHINE_NAME=$(echo $CFG | jq -r '.machine_name')
TOTAL_TRAFFIC=$(echo $CFG | jq -r '.total_traffic')
RESET_DAY=$(echo $CFG | jq -r '.reset_day')
TG_API_KEY=$(echo $CFG | jq -r '.tg_api_key')
CHAT_ID=$(echo $CFG | jq -r '.chat_id')

# 默认值，防止空值导致错误
TOTAL_TRAFFIC=${TOTAL_TRAFFIC:-0}
RESET_DAY=${RESET_DAY:-1}
today_day=$(date +%d)
today_day=${today_day:-1}

for cmd in vnstat curl jq bc; do
    command -v $cmd >/dev/null 2>&1 || { echo "$cmd 未安装"; exit 1; }
done

# ------------------- 日期和周期计算 -------------------
get_valid_date() {
    local year=$1
    local month=$2
    local day=$3
    valid_date=$(date -d "$year-$month-$day" +%Y-%m-%d 2>/dev/null)
    if [ $? -ne 0 ]; then
        valid_date=$(date -d "$year-$month-01 +1 month -1 day" +%Y-%m-%d)
    fi
    echo $valid_date
}

if [[ $today_day -ge $RESET_DAY ]]; then
    PERIOD_START=$(get_valid_date $(date +%Y) $(date +%m) $RESET_DAY)
    next_month=$(date -d "$PERIOD_START +1 month" +%Y-%m)
    YEAR=$(date -d "$next_month-01" +%Y)
    MONTH=$(date -d "$next_month-01" +%m)
    PERIOD_END=$(get_valid_date $YEAR $MONTH $RESET_DAY)
else
    last_month=$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)
    YEAR=$(date -d "$last_month-01" +%Y)
    MONTH=$(date -d "$last_month-01" +%m)
    PERIOD_START=$(get_valid_date $YEAR $MONTH $RESET_DAY)
    PERIOD_END=$(get_valid_date $(date +%Y) $(date +%m) $RESET_DAY)
fi

PERIOD_START_SEC=$(date -d "$PERIOD_START" +%s)
PERIOD_END_SEC=$(date -d "$PERIOD_END" +%s)
TODAY_SEC=$(date +%s)
REMAIN_DAYS=$(( (PERIOD_END_SEC - TODAY_SEC) / 86400 ))

# ------------------- 昨日流量 -------------------
YESTERDAY=$(vnstat -d | grep "yesterday" | awk '{print $2, $3, $4}')
YESTERDAY_DOWNLOAD_BYTES=$(echo $YESTERDAY | awk '{print $1}')
YESTERDAY_UPLOAD_BYTES=$(echo $YESTERDAY | awk '{print $2}')
YESTERDAY_TOTAL_BYTES=$(echo $YESTERDAY | awk '{print $3}')

convert_bytes() {
    local bytes=$1
    if [[ -z $bytes ]]; then bytes=0; fi
    if [ $bytes -ge 1099511627776 ]; then echo "$(echo "scale=2; $bytes / 1099511627776" | bc) TB"
    elif [ $bytes -ge 1073741824 ]; then echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    elif [ $bytes -ge 1048576 ]; then echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    elif [ $bytes -ge 1024 ]; then echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
    else echo "$bytes B"; fi
}

YESTERDAY_DOWNLOAD=$(convert_bytes $YESTERDAY_DOWNLOAD_BYTES)
YESTERDAY_UPLOAD=$(convert_bytes $YESTERDAY_UPLOAD_BYTES)
YESTERDAY_TOTAL=$(convert_bytes $YESTERDAY_TOTAL_BYTES)
YESTERDAY_DATE=$(date -d "yesterday" +%Y-%m-%d)

# ------------------- 本周期累计流量 -------------------
USED_BYTES=$(vnstat --json | jq -r ".interfaces[0].traffic.month[] | select(.date.year*100+.date.month >= $(date -d $PERIOD_START +%Y%m) and .date.year*100+.date.month <= $(date -d $PERIOD_END +%Y%m)) | .rx + .tx" | awk '{sum += $1} END {print sum}')
USED_BYTES=${USED_BYTES:-0}
TOTAL_BYTES=$(echo "$TOTAL_TRAFFIC*1073741824" | bc)
TOTAL_BYTES=${TOTAL_BYTES:-0}
REMAIN_BYTES=$(echo "$TOTAL_BYTES - $USED_BYTES" | bc)

USED_STR=$(convert_bytes $USED_BYTES)
REMAIN_STR=$(convert_bytes $REMAIN_BYTES)
TOTAL_STR=$(convert_bytes $TOTAL_BYTES)

overall_progress=$(echo "scale=2; ($USED_BYTES / $TOTAL_BYTES) * 100" | bc 2>/dev/null)
overall_progress=${overall_progress:-0}
overall_progress=$(printf "%.0f" $overall_progress)

get_progress_bar() {
    local progress=$1
    local color
    if [[ $progress -lt 50 ]]; then color="🟨"
    elif [[ $progress -lt 90 ]]; then color="🟩"
    else color="🟥"; fi
    local filled=$((progress / 10))
    local empty=$((10 - filled))
    printf "%s%s%s" "$color" "$(printf "⬛%.0s" $(seq 1 $filled))" "$(printf "⬜%.0s" $(seq 1 $empty))"
}

PROGRESS_BAR=$(get_progress_bar $overall_progress)

# ------------------- Telegram 消息 -------------------
message="📊 **每日流量报告**

🏷 机器: $MACHINE_NAME
📅 日期: $YESTERDAY_DATE
🔽 下载: $YESTERDAY_DOWNLOAD
🔼 上传: $YESTERDAY_UPLOAD
📊 总计: $YESTERDAY_TOTAL

💡 **总流量概览**
$PROGRESS_BAR  $overall_progress%
✅ 已用: $USED_STR
⚪ 剩余: $REMAIN_STR
总量: $TOTAL_STR

⏳ 剩余周期天数: $REMAIN_DAYS
周期: $PERIOD_START ~ $PERIOD_END"

curl -s -X POST "https://api.telegram.org/bot$TG_API_KEY/sendMessage" \
-d chat_id="$CHAT_ID" -d text="$message" -d parse_mode="Markdown"
EOL

    chmod +x $SCRIPT_FILE
}

# ------------------- 安装 -------------------
install_script() {
    read -p "请输入机器名称（不能为空）：" MACHINE_NAME
    [[ -z "$MACHINE_NAME" ]] && echo "机器名称不能为空！" && exit 1

    read -p "请输入总流量（GB，数字）：" TOTAL_TRAFFIC
    if [[ -z "$TOTAL_TRAFFIC" || ! "$TOTAL_TRAFFIC" =~ ^[0-9]+$ ]]; then
        echo "总流量必须为数字！"
        exit 1
    fi

    read -p "请输入重置日（每月几号，1-31）：" RESET_DAY
    if [[ -z "$RESET_DAY" || ! "$RESET_DAY" =~ ^[0-9]+$ || $RESET_DAY -lt 1 || $RESET_DAY -gt 31 ]]; then
        echo "重置日必须是1-31之间数字"
        exit 1
    fi

    read -p "请输入 Telegram Bot API Key：" TG_API_KEY
    [[ -z "$TG_API_KEY" ]] && echo "Telegram API Key 不能为空" && exit 1

    read -p "请输入 Telegram Chat ID：" CHAT_ID
    [[ -z "$CHAT_ID" ]] && echo "Telegram Chat ID 不能为空" && exit 1

    mkdir -p /etc
    cat > $CONFIG_FILE <<EOL
{
    "machine_name": "$MACHINE_NAME",
    "total_traffic": "$TOTAL_TRAFFIC",
    "reset_day": "$RESET_DAY",
    "tg_api_key": "$TG_API_KEY",
    "chat_id": "$CHAT_ID"
}
EOL

    generate_execution_script

    # systemd 定时任务
    cat > $SERVICE_FILE <<EOL
[Unit]
Description=Daily Traffic Report
[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
[Install]
WantedBy=multi-user.target
EOL

    cat > $TIMER_FILE <<EOL
[Unit]
Description=Run Daily Traffic Report at 1am
[Timer]
OnCalendar=*-*-* 01:00:00
[Install]
WantedBy=timers.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable traffic_report.timer
    sudo systemctl start traffic_report.timer

    echo "安装完成，每天 1 点自动推送 Telegram 流量报告。"
}

# ------------------- 更新 -------------------
update_script() {
    [[ ! -f "$SCRIPT_FILE" ]] && echo "脚本未安装，请先安装" && exit 1
    generate_execution_script
    sudo systemctl restart traffic_report.timer
    echo "执行脚本已更新，配置保持不变"
}

# ------------------- 卸载 -------------------
uninstall_script() {
    sudo systemctl stop traffic_report.timer
    sudo systemctl disable traffic_report.timer
    sudo rm -f $TIMER_FILE $SERVICE_FILE $SCRIPT_FILE $CONFIG_FILE
    echo "脚本和定时任务已卸载。"
}

# ------------------- 主菜单 -------------------
echo "请选择操作："
echo "1. 安装"
echo "2. 更新"
echo "3. 卸载"
read -p "请输入编号 (1/2/3): " OPTION

case $OPTION in
1)
    install_dependencies
    install_script
    ;;
2)
    update_script
    ;;
3)
    uninstall_script
    ;;
*)
    echo "无效选项，退出。"
    exit 1
    ;;
esac
