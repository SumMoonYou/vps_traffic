#!/bin/bash
# install_vps_vnstat.sh v1.7.2
# 功能：基于 vnStat 的流量统计，并通过 Telegram Bot 发送每日报表
set -u

# ================= 配置路径与变量 =================
VERSION="v1.7.2"
CONFIG_FILE="/etc/vps_vnstat_config.conf"             # 用户配置文件路径
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"   # 核心推送脚本路径
STATE_DIR="/var/lib/vps_vnstat_telegram"              # 状态快照目录
STATE_FILE="$STATE_DIR/state.json"                    # 用于存储周期基准流量的快照文件

# ---------------- 1. 环境安装与多系统兼容 ----------------
install_dependencies() {
    echo "正在检查系统环境与依赖..."
    # 定义核心依赖：vnstat(统计), jq(解析JSON), curl(网络请求), bc(高精度计算)
    DEPS=("vnstat" "jq" "curl" "bc")
    MISSING_DEPS=()
    
    # 检查依赖是否已安装
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null; then MISSING_DEPS+=("$dep"); fi
    done

    if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
        echo "所有依赖已安装。"
    else
        echo "正在安装缺失依赖: ${MISSING_DEPS[*]} ..."
        # 根据系统包管理器进行安装
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y vnstat jq curl bc
        elif [ -f /etc/redhat-release ] || [ -f /etc/oracle-release ]; then
            yum install -y epel-release && yum install -y vnstat jq curl bc
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache vnstat jq curl bc
        else
            echo "无法识别系统，请手动安装: ${MISSING_DEPS[*]}"; exit 1
        fi
    fi

    # 启动并开机自启 vnStat 服务
    if command -v systemctl &>/dev/null; then
        systemctl enable --now vnstat 2>/dev/null || true
    fi
}

# ---------------- 2. 交互式配置引导 ----------------
generate_config() {
    mkdir -p "$STATE_DIR"
    # 如果已存在配置文件，则加载旧值作为默认值
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    
    echo -e "\n--- 流量统计配置引导 ---"
    read -rp "每月重置日 (1-31, 默认 ${RESET_DAY:-1}): " input; RESET_DAY=${input:-${RESET_DAY:-1}}
    read -rp "TG Bot Token: " input; BOT_TOKEN=${input:-${BOT_TOKEN:-}}
    read -rp "TG Chat ID: " input; CHAT_ID=${input:-${CHAT_ID:-}}
    read -rp "月流量总量 (GB, 0为不限, 默认 ${MONTH_LIMIT_GB:-0}): " input; MONTH_LIMIT_GB=${input:-${MONTH_LIMIT_GB:-0}}
    read -rp "推送小时 (0-23, 默认 ${DAILY_HOUR:-0}): " input; DAILY_HOUR=${input:-${DAILY_HOUR:-0}}
    read -rp "推送分钟 (0-59, 默认 ${DAILY_MIN:-30}): " input; DAILY_MIN=${input:-${DAILY_MIN:-30}}
    
    # 自动获取第一个活跃网卡名称
    DF_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "网卡名称 (默认 $DF_IF): " input; IFACE=${input:-${IFACE:-$DF_IF}}
    
    # 设置主机名
    [ -z "${HOSTNAME_CUSTOM:-}" ] && read -rp "主机名称 (默认 $(hostname)): " input && HOSTNAME_CUSTOM=${input:-$(hostname)}
    ALERT_PERCENT=${ALERT_PERCENT:-10} # 默认剩余 10% 时告警

    # 写入配置文件
    cat > "$CONFIG_FILE" <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
ALERT_PERCENT=$ALERT_PERCENT
HOSTNAME_CUSTOM="$HOSTNAME_CUSTOM"
EOF
    chmod 600 "$CONFIG_FILE" # 保护配置文件权限
}

# ---------------- 3. 生成核心推送脚本 ----------------
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
set -u
# 加载用户配置
source "/etc/vps_vnstat_config.conf"
STATE_FILE="/var/lib/vps_vnstat_telegram/state.json"
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# 获取基础信息
HOST=${HOSTNAME_CUSTOM:-$(hostname)}
IP=$(curl -4fsS --max-time 5 https://api.ipify.org || echo "未知")

# 强制更新 vnStat 数据库并导出 JSON
vnstat -u -i "$IFACE" >/dev/null 2>&1 || true
VNSTAT_JSON=$(vnstat -i "$IFACE" --json 2>/dev/null || echo '{}')
VNSTAT_VERSION=$(vnstat --version 2>/dev/null | head -n1 | awk '{print $2}' | cut -d'.' -f1 || echo "2")

# vnStat 1.x 和 2.x 的单位处理逻辑不同 (KiB vs Bytes)
KIB_TO_BYTES=$(( VNSTAT_VERSION >=2 ? 1 : 1024 ))
# 兼容不同版本的 JSON 路径名
TRAFFIC_PATH=$(echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length>0' &>/dev/null && echo "day" || echo "days")

# 格式化字节单位函数 (B, KB, MB, GB, TB)
format_b() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=0;while(b>=1024&&i<4){b/=1024;i++}printf "%.2f%s",b,u[i+1]}'; }

# --- [昨日流量统计逻辑] ---
T_STR="${1:-$(date -d "yesterday" '+%Y-%m-%d')}"
T_Y=$(date -d "$T_STR" '+%Y'); T_M=$((10#$(date -d "$T_STR" '+%m'))); T_D=$((10#$(date -d "$T_STR" '+%d')))
DAY_DATA=$(echo "$VNSTAT_JSON" | jq -r --argjson y $T_Y --argjson m $T_M --argjson d $T_D --arg p "$TRAFFIC_PATH" \
    '.interfaces[0].traffic[$p][]? | select(.date.year==$y and .date.month==$m and .date.day==$d) | "\(.rx) \(.tx)"' 2>/dev/null)
read -r D_RX_U D_TX_U <<< "${DAY_DATA:-0 0}"
D_RX=$(echo "$D_RX_U*$KIB_TO_BYTES" | bc); D_TX=$(echo "$D_TX_U*$KIB_TO_BYTES" | bc); D_TOTAL=$(echo "$D_RX+$D_TX" | bc)

# --- [账单周期动态判定逻辑] ---
CUR_Y=$(date +%Y); CUR_M=$((10#$(date +%m))); DOM=$((10#$(date +%d)))
# 判断今天是否已经过了重置日，从而决定周期的起止时间
if [ "$DOM" -lt "$RESET_DAY" ]; then
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY -1 month" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
else
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY +1 month" +%Y-%m-%d)
fi

# --- [周期流量计算与快照逻辑] ---
# 计算网卡自记录以来的总流量
ACC_RX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .rx]|add//0" 2>/dev/null)
ACC_TX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .tx]|add//0" 2>/dev/null)
ACC_TOTAL=$(echo "($ACC_RX_U+$ACC_TX_U)*$KIB_TO_BYTES" | bc)

# 如果没有快照，扫描历史数据对齐当前周期
if [ ! -f "$STATE_FILE" ]; then
    S_Y=$(date -d "$START_PERIOD" '+%Y'); S_M=$((10#$(date -d "$START_PERIOD" '+%m'))); S_D=$((10#$(date -d "$START_PERIOD" '+%d')))
    PERIOD_RAW=$(echo "$VNSTAT_JSON" | jq -r --argjson y $S_Y --argjson m $S_M --argjson d $S_D --arg p "$TRAFFIC_PATH" \
        '.interfaces[0].traffic[$p][]? | select(.date.year > $y or (.date.year == $y and .date.month > $m) or (.date.year == $y and .date.month == $m and .date.day >= $d)) | (.rx+.tx)' | awk '{s+=$1} END {print s+0}')
    USED_BYTES=$(echo "$PERIOD_RAW*$KIB_TO_BYTES" | bc)
    # 快照点 = 总流量 - 本周期已用
    SNAP_BASE=$(echo "$ACC_TOTAL-$USED_BYTES" | bc)
    echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$SNAP_BASE}" > "$STATE_FILE"
else
    SNAP_TOTAL=$(jq -r '.snap_total//0' "$STATE_FILE")
    SNAP_DATE=$(jq -r '.last_snapshot_date//""' "$STATE_FILE")
    # 如果进入了新的周期，重置快照
    if [[ "$SNAP_DATE" != "$START_PERIOD" ]]; then
        echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$ACC_TOTAL}" > "$STATE_FILE"
        USED_BYTES=0
    else
        # 本周期已用 = 总记录量 - 周期起始快照量
        USED_BYTES=$(echo "$ACC_TOTAL-$SNAP_TOTAL" | bc)
    fi
fi

# --- [进度条与颜色处理逻辑] ---
[ "$(echo "$USED_BYTES<0"|bc)" -eq 1 ] && USED_BYTES=0
LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
REMAIN_BYTES=0; [ "$LIMIT_BYTES" -gt 0 ] && REMAIN_BYTES=$(echo "$LIMIT_BYTES-$USED_BYTES" | bc)
[ "$(echo "$REMAIN_BYTES<0"|bc)" -eq 1 ] && REMAIN_BYTES=0

PERCENT=0; [ "$LIMIT_BYTES" -gt 0 ] && PERCENT=$(echo "($USED_BYTES*100)/$LIMIT_BYTES" | bc)
[ "$PERCENT" -gt 100 ] && PERCENT=100

# 动态进度条颜色选择
BLOCK="🟩"
if [ "$PERCENT" -ge 80 ]; then BLOCK="🟥"  # 80%以上红色
elif [ "$PERCENT" -ge 50 ]; then BLOCK="🟨" # 50%以上黄色
fi

BAR=""; FILLED=$((PERCENT*10/100))
for ((i=0;i<10;i++)); do
    if [ "$i" -lt "$FILLED" ]; then BAR+="$BLOCK"; else BAR+="⬜"; fi
done

# --- [生成 Telegram 消息体] ---
MSG="📊 *VPS 流量日报*

🖥 *主机*: $HOST
🌐 *地址*: $IP
💾 *网卡*: $IFACE
⏰ *时间*: $(date '+%Y-%m-%d %H:%M')

🗓 *昨日数据* ($T_STR)
📥 *下载*: $(format_b $D_RX)
📤 *上传*: $(format_b $D_TX)
↕️ *总计*: $(format_b $D_TOTAL)

🈷 *本周期统计*
🗓️ *区间*: \`$START_PERIOD\` ➔ \`$END_PERIOD\`
⏳️ *已用*: $(format_b $USED_BYTES)
⏳️ *剩余*: $(LIMIT_BYTES==0 && echo "不限" || format_b $REMAIN_BYTES)
⌛️ *总量*: $(LIMIT_BYTES==0 && echo "不限" || format_b $LIMIT_BYTES)
🔃 *重置*: 每月 $RESET_DAY 号

🎯 *进度*: $BAR $PERCENT%"

# 临近限额时的额外警告消息
[ "$LIMIT_BYTES" -gt 0 ] && [ "$PERCENT" -ge $((100-ALERT_PERCENT)) ] && MSG="$MSG
⚠️ *告警*: 流量消耗已达 $PERCENT%！"

# 推送
curl -s -X POST "$TG_API" -d "chat_id=$CHAT_ID" -d "parse_mode=Markdown" --data-urlencode "text=$MSG" >/dev/null
EOS
    chmod 750 "$SCRIPT_FILE"
}

# ---------------- 4. 系统计划任务 (Systemd Timer) ----------------
setup_timer() {
    source "$CONFIG_FILE"
    # 创建服务执行单元
    cat > /etc/systemd/system/vps_vnstat_telegram.service <<EOF
[Unit]
Description=VPS vnStat Telegram Report Service
[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF
    # 创建定时器单元
    cat > /etc/systemd/system/vps_vnstat_telegram.timer <<EOF
[Unit]
Description=Timer for VPS vnStat Telegram Report
[Timer]
OnCalendar=*-*-* ${DAILY_HOUR}:${DAILY_MIN}:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    # 加载并启动定时器
    systemctl daemon-reload && systemctl enable --now vps_vnstat_telegram.timer
}

# ---------------- 5. 卸载逻辑 ----------------
uninstall_all() {
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null
    rm -f /etc/systemd/system/vps_vnstat_telegram.*
    rm -rf "$STATE_DIR" "$SCRIPT_FILE" "$CONFIG_FILE"
    systemctl daemon-reload
    echo "卸查完成，相关配置及计划任务已清理。"
}

# ---------------- 入口主菜单 ----------------
show_menu() {
    echo -e "\nVPS vnStat Telegram 统计助手 $VERSION"
    echo "1. 安装 / 重新配置全部 (覆盖安装)"
    echo "2. 仅更新脚本逻辑 (保留 Bot 配置)"
    echo "3. 卸载脚本"
    echo "4. 退出"
    read -rp "请选择: " opt
    case $opt in
        1) install_dependencies; generate_config; generate_main_script; setup_timer; rm -f "$STATE_FILE"; $SCRIPT_FILE; echo "完成！";;
        2) generate_main_script; echo "逻辑更新成功。";;
        3) uninstall_all;;
        *) exit 0;;
    esac
}

show_menu
