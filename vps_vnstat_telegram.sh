#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v2.5 
# =================================================================

VERSION="v2.5"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# --- 1. 环境准备 ---
prepare_env() {
    echo "🔍 正在检查并配置系统环境..."
    local deps=("vnstat" "bc" "curl" "cron")
    local to_install=()

    for dep in "${deps[@]}"; do
        if [ "$dep" == "cron" ]; then
            if ! command -v crontab &>/dev/null; then to_install+=("cron"); fi
        elif ! command -v "$dep" &>/dev/null; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y "${to_install[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y epel-release && yum install -y "${to_install[@]}"
        fi
    fi

    systemctl enable vnstat --now >/dev/null 2>&1
    systemctl enable cron --now >/dev/null 2>&1 || systemctl enable crond --now >/dev/null 2>&1
    vnstat -u >/dev/null 2>&1
    echo "✅ 环境检查完成。"
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
EOF

    echo "BC=\"$BC_P\"" >> $BIN_PATH
    echo "VN=\"$VN_P\"" >> $BIN_PATH
    echo "CL=\"$CL_P\"" >> $BIN_PATH

    cat <<'EOF' >> $BIN_PATH
# 1. 更新数据
$VN -i $INTERFACE --update >/dev/null 2>&1
SERVER_IP=$(hostname -I | awk '{print $1}')

# 2. 单位转换函数 (增加 KiB 支持)
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    local unit=$(echo "$raw" | grep -oE '[a-zA-Z]+' | tr '[:lower:]' '[:upper:]')
    [ -z "$num" ] && num=0
    case "$unit" in
        *T*) echo "scale=2; $num * 1048576" | $BC ;;
        *G*) echo "scale=2; $num * 1024" | $BC ;;
        *M*) echo "$num" ;;
        *K*) echo "scale=2; $num / 1024" | $BC ;;
        *)   echo "$num" ;;
    esac
}

# 3. 流量提取 (核心修复：使用正则匹配提取前两个数值)
Y_DATE=$(date -d "yesterday" "+%Y-%m-%d")
Y_ALT1=$(date -d "yesterday" "+%m/%d/%Y")
Y_ALT2=$(date -d "yesterday" "+%Y年%m月%d日")
Y_ALT3=$(date -d "yesterday" "+%d.%m.%Y")
RAW_LINE=$($VN -d | grep -Ei "(yesterday|$Y_DATE|$Y_ALT1|$Y_ALT2|$Y_ALT3)")

if [ -n "$RAW_LINE" ]; then
    # 提取第一个 数值+单位 (RX)
    RX_STR=$(echo "$RAW_LINE" | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z]+' | sed -n '1p' | xargs)
    # 提取第二个 数值+单位 (TX)
    TX_STR=$(echo "$RAW_LINE" | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z]+' | sed -n '2p' | xargs)
    
    RX_MB=$(val_to_mb "$RX_STR")
    TX_MB=$(val_to_mb "$TX_STR")
    TOTAL_YEST_GB=$(echo "scale=2; ($RX_MB + $TX_MB) / 1024" | $BC)
    # 格式化显示名称
    DISP_RX="${RX_STR/GiB/GB}"; DISP_TX="${TX_STR/GiB/GB}"
else
    DISP_RX="0.00 GB"; DISP_TX="0.00 GB"; TOTAL_YEST_GB="0.00"
fi

# 4. 周期判定
TODAY_D=$(date +%d | sed 's/^0//')
THIS_Y=$(date +%Y)
THIS_M=$(date +%m)
REMARK=""

if [ "$TODAY_D" -lt "$RESET_DAY" ]; then
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY}" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi
[ "$TODAY_D" -eq "$RESET_DAY" ] && REMARK=" (新周期开始)"

# 5. 周期累计统计 (同样应用正则修复)
TOTAL_PERIOD_MB=0
CUR_TS=$(date -d "$START_DATE" +%s)
YEST_TS=$(date -d "yesterday" +%s)
while [ "$CUR_TS" -le "$YEST_TS" ]; do
    D1=$(date -d "@$CUR_TS" "+%Y-%m-%d"); D2=$(date -d "@$CUR_TS" "+%m/%d/%Y")
    D3=$(date -d "@$CUR_TS" "+%Y年%m月%d日"); D4=$(date -d "@$CUR_TS" "+%d.%m.%Y")
    D_LINE=$($VN -d | grep -E "($D1|$D2|$D3|$D4)")
    if [ -n "$D_LINE" ]; then
        D_RX_STR=$(echo "$D_LINE" | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z]+' | sed -n '1p')
        D_TX_STR=$(echo "$D_LINE" | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z]+' | sed -n '2p')
        TOTAL_PERIOD_MB=$(echo "$TOTAL_PERIOD_MB + $(val_to_mb "$D_RX_STR") + $(val_to_mb "$D_TX_STR")" | $BC)
    fi
    CUR_TS=$((CUR_TS + 86400))
done

USED_GB=$(printf "%.2f" "$(echo "$TOTAL_PERIOD_MB / 1024" | $BC)")
PCT=$(echo "scale=0; $USED_GB * 100 / $MAX_GB" | $BC 2>/dev/null)
[ -z "$PCT" ] && PCT=0

# 6. 生成进度条
gen_bar() {
    local p=$1; local b=""; [ "$p" -gt 100 ] && p=100
    local c="🟩"; [ "$p" -ge 50 ] && c="🟧"; [ "$p" -ge 80 ] && c="🟥"
    for ((i=0; i<p/10; i++)); do b+="$c"; done
    for ((i=p/10; i<10; i++)); do b+="⬜"; done
    echo "$b"
}
BAR=$(gen_bar $PCT)
NOW=$(date "+%Y-%m-%d %H:%M")

# 7. 构建消息并发往 Telegram
MSG=$(printf "📊 *流量日报 (%s)*\n\n💻*主机：*%s\n🛜 *地址：* %s\n\n⬇️ *下载：* %s\n⬆️ *上传：* %s\n🧮 *合计：* %s GB\n\n📅 *周期：* %s ~ %s\n🔄 *重置：* 每月 %s 号\n⏳ *累计：* %s / %s GB%s\n🎯 *进度：* %s %d%%\n\n🕙 %s" \
"$Y_DATE" \
"$HOST_ALIAS" \
"$SERVER_IP" \
"$DISP_RX" \
"$DISP_TX" \
"$TOTAL_YEST_GB" \
"$START_DATE" \
"$END_DATE" \
"$RESET_DAY" \
"$USED_GB" \
"$MAX_GB" \
"$REMARK" \
"$BAR" \
"$PCT" \
"$NOW")

$CL --connect-timeout 10 --retry 3 -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
-d "chat_id=$TG_CHAT_ID" \
-d "text=$MSG" \
-d "parse_mode=Markdown" \
-d "disable_notification=true" > /dev/null

EOF
    chmod +x $BIN_PATH
}

# --- 3. 配置录入 ---
collect_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    echo "--- 请输入配置参数 ---"
    read -p "👤 主机别名 [${HOST_ALIAS}]: " input_val; HOST_ALIAS=${input_val:-$HOST_ALIAS}
    read -p "🤖 Bot Token [${TG_TOKEN}]: " input_val; TG_TOKEN=${input_val:-$TG_TOKEN}
    read -p "🆔 Chat ID [${TG_CHAT_ID}]: " input_val; TG_CHAT_ID=${input_val:-$TG_CHAT_ID}
    read -p "📅 重置日 (1-31) [${RESET_DAY}]: " input_val; RESET_DAY=${input_val:-$RESET_DAY}
    read -p "📊 限额 (GB) [${MAX_GB}]: " input_val; MAX_GB=${input_val:-$MAX_GB}
    
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
    echo " 1. 全新安装 / 覆盖安装"
    echo " 2. 修改配置"
    echo " 3. 仅更新脚本逻辑"
    echo " 4. 手动发送一次报表 (测试)"
    echo " 5. 彻底卸载工具"
    echo " 6. 退出"
    echo "==========================================="
    read -p "请选择 [1-6]: " choice
    case $choice in
        1) prepare_env; collect_config; echo "✅ 安装并配置完成！"; sleep 2 ;;
        2) collect_config; echo "✅ 配置更新成功！"; sleep 2 ;;
        3) generate_report_logic; echo "✅ 逻辑已更新！"; sleep 1 ;;
        4) $BIN_PATH && echo "✅ 测试报表已尝试发送！" || echo "❌ 发送失败，请检查配置"; sleep 2 ;;
        5) (crontab -l | grep -v "$BIN_PATH") | crontab -; rm -f "$BIN_PATH" "$CONFIG_FILE"; echo "✅ 工具已卸载"; sleep 2 ;;
        6) exit 0 ;;
    esac
done
