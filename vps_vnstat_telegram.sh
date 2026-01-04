set -u

VERSION="v2.1"
CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"

# --- 1. 环境检查与依赖补全 ---
install_deps() {
    echo "正在扫描系统环境并补全依赖..."
    DEPS=("vnstat" "curl" "awk" "bc" "jq")
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y "${DEPS[@]}"
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y "${DEPS[@]}"
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache "${DEPS[@]}"
    fi
    systemctl enable --now vnstat 2>/dev/null || true
    vnstat -u >/dev/null 2>&1
}

# --- 2. 配置引导 ---
load_and_setup_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    
    # 默认值设置
    RESET_DAY=${RESET_DAY:-11}
    BOT_TOKEN=${BOT_TOKEN:-""}
    CHAT_ID=${CHAT_ID:-""}
    MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-1000}
    PUSH_TIME=${PUSH_TIME:-"22:20"}
    DF_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|docker|veth" | head -n1)
    IFACE=${IFACE:-$DF_IF}
    HOSTNAME_CUSTOM=${HOSTNAME_CUSTOM:-""}

    echo -e "\n--- [配置引导] ---"
    read -rp "1. 主机名称 (当前: $HOSTNAME_CUSTOM): " h_name; HOSTNAME_CUSTOM=${h_name:-$HOSTNAME_CUSTOM}
    read -rp "2. 重置日 (当前: $RESET_DAY): " r_day; RESET_DAY=$(echo "${r_day:-$RESET_DAY}" | tr -cd '0-9')
    read -rp "3. TG Bot Token: " token; BOT_TOKEN=${token:-$BOT_TOKEN}
    read -rp "4. TG Chat ID: " chatid; CHAT_ID=${chatid:-$CHAT_ID}
    read -rp "5. 月流量总量 (GB): " limit; MONTH_LIMIT_GB=$(echo "${limit:-$MONTH_LIMIT_GB}" | tr -cd '0-9')
    read -rp "6. 推送时间 (HH:MM): " ptime; PUSH_TIME=${ptime:-$PUSH_TIME}
    read -rp "7. 网卡名称 (当前: $IFACE): " if_input; IFACE=${if_input:-$IFACE}

    cat > "$CONFIG_FILE" <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
PUSH_TIME="$PUSH_TIME"
IFACE="$IFACE"
HOSTNAME_CUSTOM="$HOSTNAME_CUSTOM"
EOF
}

# --- 3. 生成核心推送脚本 ---
generate_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
[ -f "/etc/vps_vnstat_config.conf" ] && . "/etc/vps_vnstat_config.conf"

# 鲁棒的单位换算函数
fmt_size() {
    local val=${1:-0}
    # 剔除可能存在的非数字字符
    val=$(echo "$val" | tr -cd '0-9.')
    [ -z "$val" ] && val=0
    echo "$val" | awk '{
        split("B KB MB GB TB", u, " ");
        i=1; v=$1;
        while(v >= 1024 && i < 5) { v /= 1024; i++; }
        if(i==1) printf "%d%s", v, u[i]; else printf "%.2f%s", v, u[i];
    }'
}

# 1. 基础数据
IP=$(curl -s --max-time 5 https://api.ipify.org || echo "未知")
V_DATA=$(vnstat -i "$IFACE" --oneline b 2>/dev/null)
# 如果 vnstat 没数据，填充 mock 数据防止 cut 报错
[ -z "$V_DATA" ] && V_DATA="1;0;0;0;0;0;0;0;0;0;0;0;0;0;0"

Y_RX=$(echo "$V_DATA" | cut -d';' -f3)
Y_TX=$(echo "$V_DATA" | cut -d';' -f4)
Y_TOT=$(echo "$V_DATA" | cut -d';' -f5)

# 2. 周期判定
CUR_Y=$(date +%Y); CUR_M=$(date +%m); CUR_D=$(date +%d | sed 's/^0//')
if [ "$CUR_D" -lt "$RESET_DAY" ]; then
    S_DATE=$(date -d "${CUR_Y}-${CUR_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    E_DATE=$(date -d "${CUR_Y}-${CUR_M}-${RESET_DAY}" +%Y-%m-%d)
else
    S_DATE=$(date -d "${CUR_Y}-${CUR_M}-${RESET_DAY}" +%Y-%m-%d)
    E_DATE=$(date -d "${CUR_Y}-${CUR_M}-${RESET_DAY} +1 month" +%Y-%m-%d)
fi

# 3. 本周期统计 (加入空值保护)
JSON_RAW=$(vnstat -i "$IFACE" --begin "$S_DATE" --json 2>/dev/null)
M_TOT_B=$(echo "$JSON_RAW" | jq -r '(.interfaces[0].traffic.day // []) | map(.rx + .tx) | add // 0' 2>/dev/null)
[ -z "$M_TOT_B" ] && M_TOT_B=0

L_B=$(awk -v g="${MONTH_LIMIT_GB:-1000}" 'BEGIN{print g*1024*1024*1024}')
REM_B=$(awk -v l="$L_B" -v u="$M_TOT_B" 'BEGIN{r=l-u; print (r<0?0:r)}')
PCT=$(awk -v used="$M_TOT_B" -v limit="$L_B" 'BEGIN{if(limit<=0) print 0; else {p=(used/limit)*100; printf "%.0f", (p>100?100:p)}}')

# 4. 彩色进度条
BAR=$(awk -v p="$PCT" 'BEGIN {
    if(p < 50) color="🟩"; else if(p < 80) color="🟧"; else color="🟥";
    full=int(p/10); res="";
    for(i=0; i<full; i++) res=res color;
    for(i=full; i<10; i++) res=res "⬜";
    print res;
}')

# 5. 最终消息模板
MSG="📊 *VPS 流量日报*

🖥 *主机:* $HOSTNAME_CUSTOM
🌐 *地址:* $IP
💾 *网卡:* $IFACE
⏰ *时间:* $(date '+%Y-%m-%d %H:%M')

🗓 *昨日数据* ($(date -d yesterday +%Y-%m-%d))
📥 *下载:* $(fmt_size $Y_RX)
📤 *上传:* $(fmt_size $Y_TX)
↕️ *总计:* $(fmt_size $Y_TOT)

🈷 *本周期统计*
🗓️ *区间:* $S_DATE ➔ $E_DATE
⏳️ *已用:* $(fmt_size $M_TOT_B)
⏳️ *剩余: *$(fmt_size $REM_B)
⌛️ *总量:* $(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{if(g>=1024) printf "%.2fTB", g/1024; else printf "%dGB", g}')
🔃 *重置:* 每月 $RESET_DAY 号

🎯 *进度:* $BAR $PCT %"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" -d "parse_mode=Markdown" --data-urlencode "text=$MSG"
EOS
    chmod +x "$SCRIPT_FILE"
}

# --- 4. Systemd 定时器设置 ---
setup_timer() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    H=$(echo "${PUSH_TIME:-22:20}" | cut -d: -f1); M=$(echo "${PUSH_TIME:-22:20}" | cut -d: -f2)
    cat > /etc/systemd/system/vps_vnstat_telegram.timer <<EOF
[Unit]
Description=Traffic Report Timer
[Timer]
OnCalendar=*-*-* $H:$M:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/vps_vnstat_telegram.service <<EOF
[Unit]
Description=Traffic Report Service
[Service]
ExecStart=$SCRIPT_FILE
EOF
    systemctl daemon-reload && systemctl enable --now vps_vnstat_telegram.timer
}

# --- 5. 主菜单 ---
clear
echo "===================================="
echo "   VPS 流量助手 $VERSION (终极版)"
echo "===================================="
echo " 1) 安装"
echo " 2) 升级"
echo " 3) 立即发送测试通知"
echo " 4) 卸载"
echo " 5) 退出"
echo "===================================="
read -rp "请选择 [1-5]: " opt
case ${opt:-5} in
    1) install_deps; load_and_setup_config; generate_script; setup_timer; $SCRIPT_FILE ;;
    2) generate_script; setup_timer; echo "升级完成！"; $SCRIPT_FILE ;;
    3) $SCRIPT_FILE ;;
    4) systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null; rm -f "$SCRIPT_FILE" "$CONFIG_FILE"; echo "已卸载" ;;
    *) exit 0 ;;
esac
