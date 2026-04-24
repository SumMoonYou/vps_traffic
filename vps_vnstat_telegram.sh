#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v3.5
# =================================================================

VERSION="v3.5"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# --- 1. 环境准备 ---
prepare_env() {
    echo "🔍 正在检查系统环境..."
    local deps=("vnstat" "bc" "curl" "cron")
    if [ -f /etc/debian_version ]; then
        PACKAGE_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        PACKAGE_MANAGER="yum"
    else
        echo "❌ 未知操作系统"
        exit 1
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "安装依赖: $dep"
            if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
                sudo apt-get update && sudo apt-get install -y "$dep"
            elif [ "$PACKAGE_MANAGER" == "yum" ]; then
                sudo yum install -y "$dep"
            fi
        fi
    done

    if ! command -v cron &>/dev/null; then
        [ "$PACKAGE_MANAGER" == "apt-get" ] && sudo apt-get install -y cron || sudo yum install -y cronie
        sudo systemctl enable cron --now
    fi

    if ! systemctl is-active --quiet vnstat; then
        sudo systemctl enable vnstat --now
    fi
    sudo vnstat -u >/dev/null 2>&1
    echo "✅ 环境就绪。"
}

# --- 2. 核心逻辑生成 ---
generate_report_logic() {
    local BC_P=$(which bc)
    local VN_P=$(which vnstat)
    local CL_P=$(which curl)

    cat <<'EOF' > $BIN_PATH
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -f "/etc/vnstat_tg.conf" ] && source "/etc/vnstat_tg.conf" || exit 1

# 统一单位缩写处理
clean_unit() {
    echo "$1" | sed 's/iB/B/g'
}

# 补全前导零
fix_zero() {
    [[ $1 == .* ]] && echo "0$1" || echo "$1"
}

val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "$num" ] && num=0
    case "$raw" in
        *T*) echo "scale=2; $num * 1048576" | $BC ;;
        *G*) echo "scale=2; $num * 1024" | $BC ;;
        *K*) echo "scale=2; $num / 1024" | $BC ;;
        *)   echo "$num" ;;
    esac
}

get_traffic() {
    echo "$1" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n "${2}p" | xargs
}

$VN -i $INTERFACE --update >/dev/null 2>&1
SERVER_IP=$(hostname -I | awk '{print $1}')

# 昨日数据匹配
Y_D=$(date -d "yesterday" "+%Y-%m-%d")
Y_A1=$(date -d "yesterday" "+%m/%d/%y")
Y_A2=$(date -d "yesterday" "+%d.%m.%y")
Y_A3=$(date -d "yesterday" "+%m/%d/%Y")
RAW_LINE=$($VN -d | grep -Ei "yesterday|$Y_D|$Y_A1|$Y_A2|$Y_A3")

if [ -n "$RAW_LINE" ]; then
    RX_STR=$(get_traffic "$RAW_LINE" 1)
    TX_STR=$(get_traffic "$RAW_LINE" 2)
    RX_MB=$(val_to_mb "$RX_STR")
    TX_MB=$(val_to_mb "$TX_STR")
    
    TOTAL_YEST_MB=$(echo "scale=2; $RX_MB + $TX_MB" | $BC)
    if [ $(echo "$TOTAL_YEST_MB < 1024" | $BC) -eq 1 ]; then
        TOTAL_YEST_DISP="$(fix_zero $TOTAL_YEST_MB) MB"
    else
        TOTAL_YEST_GB=$(echo "scale=2; $TOTAL_YEST_MB / 1024" | $BC)
        TOTAL_YEST_DISP="$(fix_zero $TOTAL_YEST_GB) GB"
    fi
    DISP_RX=$(clean_unit "$RX_STR")
    DISP_TX=$(clean_unit "$TX_STR")
else
    DISP_RX="0 MB"; DISP_TX="0 MB"; TOTAL_YEST_DISP="0 MB"
fi

# 周期计算
TODAY_D=$(date +%d | sed 's/^0//')
THIS_Y=$(date +%Y); THIS_M=$(date +%m)
if [ "$TODAY_D" -lt "$RESET_DAY" ]; then
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY}" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi

TOTAL_PERIOD_MB=0
CUR_TS=$(date -d "$START_DATE" +%s)
YEST_TS=$(date -d "yesterday" +%s)
while [ "$CUR_TS" -le "$YEST_TS" ]; do
    D_DATE=$(date -d "@$CUR_TS" "+%Y-%m-%d")
    D_LINE=$($VN -d | grep "$D_DATE")
    if [ -n "$D_LINE" ]; then
        D_RX_S=$(get_traffic "$D_LINE" 1)
        D_TX_S=$(get_traffic "$D_LINE" 2)
        TOTAL_PERIOD_MB=$(echo "$TOTAL_PERIOD_MB + $(val_to_mb "$D_RX_S") + $(val_to_mb "$D_TX_S")" | $BC)
    fi
    CUR_TS=$((CUR_TS + 86400))
done

USED_GB=$(echo "scale=2; $TOTAL_PERIOD_MB / 1024" | $BC)
USED_GB_FIXED=$(fix_zero $USED_GB)
PCT=$(echo "scale=0; $TOTAL_PERIOD_MB * 100 / ($MAX_GB * 1024)" | $BC 2>/dev/null)
[ -z "$PCT" ] && PCT=0

gen_bar() {
    local p=$1; local b=""; [ "$p" -gt 100 ] && p=100
    local c="🟩"; [ "$p" -ge 50 ] && c="🟧"; [ "$p" -ge 80 ] && c="🟥"
    for ((i=0; i<p/10; i++)); do b+="$c"; done
    for ((i=p/10; i<10; i++)); do b+="⬜"; done
    echo "$b"
}
BAR=$(gen_bar $PCT)
NOW=$(date "+%Y-%m-%d %H:%M")

# --- 消息构建 (弃用 printf 以免错位) ---
MSG="📊 *流量日报*

💻 主机： *$HOST_ALIAS*
🛜 地址： \`$SERVER_IP\`

⬇️ 下载： \`$DISP_RX\`
⬆️ 上传： \`$DISP_TX\`
🧮 合计： \`$TOTAL_YEST_DISP\`

📅 周期： \`$START_DATE ~ $END_DATE\`
🔄 重置： 每月 $RESET_DAY 号

⏳ 累计： \`$USED_GB_FIXED / $MAX_GB GB\`
🎯 进度： $BAR \`$PCT%\`

🕙 \`$NOW\`"

$CL --connect-timeout 10 --retry 3 -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
-d "chat_id=$TG_CHAT_ID" \
-d "text=$MSG" \
-d "parse_mode=Markdown" \
-d "disable_notification=true" > /dev/null
EOF
    # 注入路径变量
    sed -i "4i BC=\"$BC_P\"\nVN=\"$VN_P\"\nCL=\"$CL_P\"" $BIN_PATH
    chmod +x $BIN_PATH
}

# --- 3. 配置录入 ---
collect_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    echo "--- 请输入配置参数 ---"
    read -p "👤 主机别名 [${HOST_ALIAS:-MyServer}]: " input_val; HOST_ALIAS=${input_val:-${HOST_ALIAS:-MyServer}}
    read -p "🤖 Bot Token [${TG_TOKEN}]: " input_val; TG_TOKEN=${input_val:-$TG_TOKEN}
    read -p "🆔 Chat ID [${TG_CHAT_ID}]: " input_val; TG_CHAT_ID=${input_val:-$TG_CHAT_ID}
    read -p "📅 重置日 (1-31) [${RESET_DAY:-1}]: " input_val; RESET_DAY=${input_val:-${RESET_DAY:-1}}
    read -p "📊 限额 (GB) [${MAX_GB:-1000}]: " input_val; MAX_GB=${input_val:-${MAX_GB:-1000}}
    IF_DEF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    read -p "🌐 网卡 [${INTERFACE:-$IF_DEF}]: " input_val; INTERFACE=${input_val:-${INTERFACE:-$IF_DEF}}
    read -p "⏰ 时间 (HH:MM) [${RUN_TIME:-01:30}]: " input_val; RUN_TIME=${input_val:-${RUN_TIME:-01:30}}

    cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$INTERFACE"
RUN_TIME="$RUN_TIME"
EOF

    generate_report_logic
    H=$(echo $RUN_TIME | cut -d: -f1 | sed 's/^0//'); [ -z "$H" ] && H=0
    M=$(echo $RUN_TIME | cut -d: -f2 | sed 's/^0//'); [ -z "$M" ] && M=0
    (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH"; echo "$M $H * * * /bin/bash $BIN_PATH") | crontab -
}

# --- 4. 菜单 ---
while true; do
    clear
    echo "==========================================="
    echo "    流量统计 TG 管理工具 $VERSION"
    echo "==========================================="
    echo " 1. 全新安装"
    echo " 2. 修改配置参数"
    echo " 3. 仅更新脚本逻辑"
    echo " 4. 手动发送测试报表"
    echo " 5. 彻底卸载"
    echo " 6. 退出"
    echo "==========================================="
    read -p "请选择 [1-6]: " choice
    case $choice in
        1) prepare_env; collect_config; echo "✅ 安装完成！"; sleep 2 ;;
        2) collect_config; echo "✅ 配置更新成功！"; sleep 2 ;;
        3) generate_report_logic; echo "✅ 逻辑已更新！"; sleep 1 ;;
        4) $BIN_PATH && echo "✅ 已发送测试报表！" || echo "❌ 发送失败"; sleep 2 ;;
        5) (crontab -l | grep -v "$BIN_PATH") | crontab -; rm -f "$BIN_PATH" "$CONFIG_FILE"; echo "✅ 已卸载"; sleep 2 ;;
        6) exit 0 ;;
    esac
done
