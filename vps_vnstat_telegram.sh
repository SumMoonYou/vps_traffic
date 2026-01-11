#!/bin/bash

# =================================================================
# 名称: 流量统计 & TG日报管理工具
# 版本: v1.7.7
# =================================================================

VERSION="v1.7.7"
CONFIG_FILE="/etc/vnstat_tg.conf"
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"

# --- 生成核心执行脚本 ---
generate_report_logic() {
cat <<'EOF' > $BIN_PATH
#!/bin/bash
# 加载配置
[ -f "/etc/vnstat_tg.conf" ] && source /etc/vnstat_tg.conf || exit 1

# 1. 环境准备
vnstat -u -i $INTERFACE >/dev/null 2>&1
SERVER_IP=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org || echo "Unknown")

# 流量单位换算
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    local unit=$(echo "$raw" | grep -oE '[a-zA-Z]+' | tr '[:lower:]' '[:upper:]')
    [ -z "$num" ] && num=0
    case "$unit" in
        *T*) echo "scale=2; $num * 1048576" | bc ;;
        *G*) echo "scale=2; $num * 1024" | bc ;;
        *M*) echo "$num" ;;
        *K*) echo "scale=4; $num / 1024" | bc ;;
        *)   echo "$num" ;;
    esac
}

# 2. 提取数据
REPORT_DATE=$(date -d "yesterday" "+%Y-%m-%d")
Y_CN=$(date -d "yesterday" "+%Y年%m月%d日")
Y_EN=$(date -d "yesterday" "+%Y-%m-%d")
RAW_LINE=$(vnstat -d | grep -E "($Y_CN|$Y_EN)")

if [ -n "$RAW_LINE" ]; then
    M_DATE=$(echo "$RAW_LINE" | grep -oE "([0-9]{4}年[0-9]{2}月[0-9]{2}日|[0-9]{4}-[0-9]{2}-[0-9]{2})")
    RX_YEST_STR=$(echo "$RAW_LINE" | awk -F'|' '{print $1}' | sed "s/$M_DATE//g" | xargs)
    TX_YEST_STR=$(echo "$RAW_LINE" | awk -F'|' '{print $2}' | xargs)
    RX_MB=$(val_to_mb "$RX_YEST_STR")
    TX_MB=$(val_to_mb "$TX_YEST_STR")
    TOTAL_YEST_GB=$(echo "scale=2; ($RX_MB + $TX_MB) / 1024" | bc)
    DISP_RX="${RX_YEST_STR/GiB/GB}"; DISP_TX="${TX_YEST_STR/GiB/GB}"
else
    DISP_RX="N/A"; DISP_TX="N/A"; TOTAL_YEST_GB="0.00"
fi

# 3. 计费周期判定
TODAY_D=$(date +%d | sed 's/^0//')
YEST_Y=$(date -d "yesterday" +%Y); YEST_M=$(date -d "yesterday" +%m)
if [ "$TODAY_D" -le "$RESET_DAY" ]; then
    START_DATE=$(date -d "${YEST_Y}-${YEST_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=$(date -d "${YEST_Y}-${YEST_M}-${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=$(date -d "${YEST_Y}-${YEST_M}-${RESET_DAY}" +%Y-%m-%d)
    END_DATE=$(date -d "${YEST_Y}-${YEST_M}-${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi

# 4. 周期累计
TOTAL_PERIOD_MB=0
CUR_TS=$(date -d "$START_DATE" +%s)
YEST_TS=$(date -d "yesterday" +%s)
while [ "$CUR_TS" -le "$YEST_TS" ]; do
    D_CN=$(date -d "@$CUR_TS" "+%Y年%m月%d日"); D_EN=$(date -d "@$CUR_TS" "+%Y-%m-%d")
    D_LINE=$(vnstat -d | grep -E "($D_CN|$D_EN)")
    if [ -n "$D_LINE" ]; then
        MATCH=$(echo "$D_LINE" | grep -oE "([0-9]{4}年[0-9]{2}月[0-9]{2}日|[0-9]{4}-[0-9]{2}-[0-9]{2})")
        D_RX=$(echo "$D_LINE" | awk -F'|' '{print $1}' | sed "s/$MATCH//g" | xargs)
        D_TX=$(echo "$D_LINE" | awk -F'|' '{print $2}' | xargs)
        TOTAL_PERIOD_MB=$(echo "$TOTAL_PERIOD_MB + $(val_to_mb "$D_RX") + $(val_to_mb "$D_TX")" | bc)
    fi
    CUR_TS=$((CUR_TS + 86400))
done

# 5. 计算进度与发送
USED_GB=$(echo "scale=2; $TOTAL_PERIOD_MB / 1024" | bc)
PCT=$(echo "scale=0; $USED_GB * 100 / $MAX_GB" | bc 2>/dev/null)
[ -z "$PCT" ] && PCT=0
gen_bar() {
    local p=$1; local b=""; [ "$p" -gt 100 ] && p=100
    local c="🟩"; [ "$p" -ge 50 ] && c="🟧"; [ "$p" -ge 80 ] && c="🟥"
    for ((i=0; i<p/10; i++)); do b+="$c"; done
    for ((i=p/10; i<10; i++)); do b+="⬜"; done
    echo "$b"
}

MSG="📊 *流量日报 ($REPORT_DATE) | $HOST_ALIAS*

\`🏠 地址：\` \`$SERVER_IP\`
\`📥 下载：\` \`$DISP_RX\`
\`📤 上传：\` \`$DISP_TX\`
\`🈴 合计：\` \`${TOTAL_YEST_GB} GB\`

\`📅 周期：\` \`$START_DATE ~ $END_DATE\`
\`📈 累计：\` \`$USED_GB / $MAX_GB GB\`
\`🎯 进度：\` $(gen_bar $PCT) \`$PCT%\`

🕙 \`$(date "+%Y-%m-%d %H:%M")\`"

curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown" > /dev/null
EOF
chmod +x $BIN_PATH
}

# --- 环境安装 ---
install_env() {
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y jq bc vnstat curl cron >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y jq bc vnstat curl cronie >/dev/null 2>&1
    fi
    systemctl enable vnstat --now >/dev/null 2>&1
    systemctl start vnstat >/dev/null 2>&1
}

# --- 主程序 ---
while true; do
    clear
    echo "==========================================="
    echo "   流量统计 TG 管理工具  $VERSION"
    echo "==========================================="
    echo " 1. 安装 / 重新配置"
    echo " 2. 仅更新脚本逻辑"
    echo " 3. 手动测试"
    echo " 4. 退出"
    echo "==========================================="
    read -p "选择: " choice
    case $choice in
        1)
            install_env
            read -p "👤 主机别名: " HOST_ALIAS
            read -p "🤖 TG Bot Token: " TG_TOKEN
            read -p "🆔 TG Chat ID: " TG_CHAT_ID
            read -p "📅 重置日: " RESET_DAY
            read -p "📊 限额(GB): " MAX_GB
            IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
            cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$IFACE"
EOF
            generate_report_logic
            
            # --- Crontab 去重添加逻辑 ---
            CRON_CMD="0 1 * * * $BIN_PATH"
            # 提取现有的定时任务，排除掉包含脚本路径的旧任务，然后拼接新任务
            (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH"; echo "$CRON_CMD") | crontab -
            
            echo "✅ 配置完成，定时任务已设为每日 01:00 (已自动去重)"; sleep 2 ;;
        2) generate_report_logic && echo "✅ 逻辑已更新" && sleep 1 ;;
        3) $BIN_PATH && echo "✅ 测试已发送" && sleep 2 ;;
        4) exit 0 ;;
    esac
done
