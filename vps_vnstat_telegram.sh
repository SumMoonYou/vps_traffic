#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本 v1.9
# 功能：利用 vnStat 统计流量，通过 Systemd Timer 实现定时推送 Telegram 日报。

set -euo pipefail # -e: 命令失败即退出; -u: 变量未定义即报错; -o pipefail: 管道命令中任何环节失败即视为整体失败
IFS=$'\n\t'       # 设置字段分隔符，确保路径处理的安全性

# ---------------- 全局常量 ----------------
VERSION="v1.9"
CONFIG_FILE="/etc/vps_vnstat_config.conf"           # 存储用户输入的配置
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh" # 定时执行的核心逻辑脚本
STATE_DIR="/var/lib/vps_vnstat_telegram"           # 存放流量快照的目录
STATE_FILE="$STATE_DIR/state.json"                 # 记录周期起点流量的文件
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service" # Systemd 执行单元
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"     # Systemd 定时单元

# 日志辅助函数
info() { echo -e "[\e[32mINFO\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

# 权限校验：必须以 root 权限运行安装或配置
if [ "$(id -u)" -ne 0 ]; then
    err "错误：请以 root 用户运行此脚本。"
    exit 1
fi

# ---------------- 1. 依赖环境安装 ----------------
# 自动适配主流包管理器：Debian/Ubuntu, Alpine, RHEL/CentOS
install_dependencies() {
    info "正在检测并安装必要依赖 (vnstat, jq, curl, bc)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y vnstat jq curl bc
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache vnstat jq curl bc
    else
        yum install -y epel-release && yum install -y vnstat jq curl bc
    fi
    # 启用并启动 vnstat 守护进程，它是统计流量的基础
    systemctl enable --now vnstat 2>/dev/null || true
}

# ---------------- 2. 交互式配置引导 ----------------
# 用户输入将被持久化到 CONFIG_FILE 中
generate_config() {
    mkdir -p "$STATE_DIR"
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" # 如果已存在配置，读取旧值作为默认值

    echo "--- VPS 流量日报配置引导 ---"
    read -rp "每月重置日 (1-31, 默认 ${RESET_DAY:-1}): " input
    RESET_DAY=${input:-${RESET_DAY:-1}}
    
    read -rp "Telegram Bot Token: " input
    BOT_TOKEN=${input:-${BOT_TOKEN:-}}
    
    read -rp "Telegram Chat ID: " input
    CHAT_ID=${input:-${CHAT_ID:-}}
    
    read -rp "月流量总量限制 (GB, 输入0表示不限, 默认 ${MONTH_LIMIT_GB:-0}): " input
    MONTH_LIMIT_GB=${input:-${MONTH_LIMIT_GB:-0}}
    
    read -rp "推送时间-小时 (0-23, 默认 ${DAILY_HOUR:-0}): " input
    DAILY_HOUR=${input:-${DAILY_HOUR:-0}}
    
    read -rp "推送时间-分钟 (0-59, 默认 ${DAILY_MIN:-30}): " input
    DAILY_MIN=${input:-${DAILY_MIN:-30}}
    
    # 自动识别默认活跃网卡
    DF_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "监控网卡名称 (默认 $DF_IF): " input
    IFACE=${input:-${IFACE:-$DF_IF}}
    
    # 获取主机名
    [ -z "${HOSTNAME_CUSTOM:-}" ] && read -rp "日报显示的服务器名称 (默认 $(hostname)): " input && HOSTNAME_CUSTOM=${input:-$(hostname)}
    
    ALERT_PERCENT=${ALERT_PERCENT:-10} # 默认剩余 10% 流量时触发告警

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
    chmod 600 "$CONFIG_FILE" # 权限设为 600，保护 Token 安全
}

# ---------------- 3. 生成执行脚本 (主逻辑) ----------------
# 此脚本将被定时调用，负责数据计算与消息推送
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
set -euo pipefail
source "/etc/vps_vnstat_config.conf"
STATE_FILE="/var/lib/vps_vnstat_telegram/state.json"

# 获取服务器基本信息
HOST=${HOSTNAME_CUSTOM:-$(hostname)}
IP=$(curl -4fsS --max-time 5 https://api.ipify.org || echo "未知")
TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# vnstat 数据处理：强制更新数据库并获取 JSON 格式数据
vnstat -u -i "$IFACE" >/dev/null 2>&1
VNSTAT_JSON=$(vnstat -i "$IFACE" --json 2>/dev/null || echo '{}')
VNSTAT_VERSION=$(vnstat --version | head -n1 | awk '{print $2}' | cut -d'.' -f1)

# 兼容性：vnstat 2.x 以 Bytes 为单位，1.x 可能以 KiB 为单位
KIB_TO_BYTES=$(( VNSTAT_VERSION >=2 ? 1 : 1024 ))
# 兼容性：适配 JSON 里的 day 字段路径
TRAFFIC_PATH=$(echo "$VNSTAT_JSON" | jq -e '.interfaces[0].traffic.day // [] | length>0' &>/dev/null && echo "day" || echo "days")

# 单位转换函数：将 Byte 转换为人类可读格式
format_b() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=0;while(b>=1024&&i<4){b/=1024;i++}printf "%.2f%s",b,u[i+1]}'; }

# --- 1. 计算昨日流量 ---
# 默认统计昨天全天数据，也支持通过 $1 传入特定日期参数进行统计
TARGET_DATE_STR="${1:-$(date -d "yesterday" '+%Y-%m-%d')}"
T_Y=$(date -d "$TARGET_DATE_STR" '+%Y')
T_M=$((10#$(date -d "$TARGET_DATE_STR" '+%m'))) # 10# 强制识别为十进制，防止 08/09 被识别为无效八进制
T_D=$((10#$(date -d "$TARGET_DATE_STR" '+%d')))

DAY_DATA=$(echo "$VNSTAT_JSON" | jq -r --argjson y $T_Y --argjson m $T_M --argjson d $T_D --arg p "$TRAFFIC_PATH" \
    '.interfaces[0].traffic[$p][]? | select(.date.year==$y and .date.month==$m and .date.day==$d) | "\(.rx) \(.tx)"')
read -r D_RX_U D_TX_U <<< "${DAY_DATA:-0 0}"

D_RX=$(echo "$D_RX_U*$KIB_TO_BYTES" | bc)
D_TX=$(echo "$D_TX_U*$KIB_TO_BYTES" | bc)
D_TOTAL=$(echo "$D_RX+$D_TX" | bc)

# --- 2. 统计周期日期推算 ---
# 根据“重置日”动态决定统计周期的起止时间
TODAY_STR=$(date +%Y-%m-%d)
CUR_Y=$(date +%Y); CUR_M=$((10#$(date +%m))); DOM=$((10#$(date +%d)))

if [ "$DOM" -lt "$RESET_DAY" ]; then
    # 若今日还没到重置日，则周期起点是上个月的重置日
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY -1 month" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
else
    # 若今日已过重置日，则周期起点是本月的重置日
    START_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY" +%Y-%m-%d)
    END_PERIOD=$(date -d "$CUR_Y-$CUR_M-$RESET_DAY +1 month" +%Y-%m-%d)
fi

# --- 3. 流量快照逻辑 (用于计算周期内已用量) ---
# 获取网卡记录以来的历史总上传和总下载
ACC_RX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .rx]|add//0")
ACC_TX_U=$(echo "$VNSTAT_JSON" | jq "[.interfaces[0].traffic.${TRAFFIC_PATH}[]? | .tx]|add//0")
ACC_TOTAL=$(echo "($ACC_RX_U+$ACC_TX_U)*$KIB_TO_BYTES" | bc)

# 首次运行或状态文件丢失时的初始化
if [ ! -f "$STATE_FILE" ]; then
    echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$ACC_TOTAL}" > "$STATE_FILE"
fi

SNAP_TOTAL=$(jq -r '.snap_total//0' "$STATE_FILE")
SNAP_DATE=$(jq -r '.last_snapshot_date//""' "$STATE_FILE")

# 核心重置判断：若记录的快照日期晚于推算的周期起点，则更新快照，视为新周期的开始
if [[ "$SNAP_DATE" < "$START_PERIOD" ]] || [[ "$SNAP_DATE" == "" ]]; then
    SNAP_TOTAL=$ACC_TOTAL
    echo "{\"last_snapshot_date\":\"$START_PERIOD\",\"snap_total\":$ACC_TOTAL}" > "$STATE_FILE"
    SNAP_DATE=$START_PERIOD
fi

# 周期消耗 = 历史累计总量 - 周期起始点总量
USED_BYTES=$(echo "$ACC_TOTAL-$SNAP_TOTAL" | bc)
[ "$(echo "$USED_BYTES<0"|bc)" -eq 1 ] && USED_BYTES=0 # 异常处理，防止负值

# 流量余量计算
LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
REMAIN_BYTES=$(echo "$LIMIT_BYTES-$USED_BYTES" | bc)
[ "$(echo "$REMAIN_BYTES<0"|bc)" -eq 1 ] && REMAIN_BYTES=0

# 进度百分比与进度条生成
PERCENT=0; [ "$LIMIT_BYTES" -gt 0 ] && PERCENT=$(echo "($USED_BYTES*100)/$LIMIT_BYTES" | bc)
[ "$PERCENT" -gt 100 ] && PERCENT=100
BAR=""; FILLED=$((PERCENT*10/100)); for ((i=0;i<10;i++)); do [ "$i" -lt "$FILLED" ] && BAR+="🟦" || BAR+="⬜"; done

# --- 4. 组装 Markdown 消息并推送 ---
MSG="📊 *VPS 流量日报*


🖥 *主机*: $HOST
🌐 *地址*: $IP
💾 *网卡*: $IFACE
⏰ *时间*: $(date '+%Y-%m-%d %H:%M')

🗓︎ *昨日数据* ($TARGET_DATE_STR)
📥 *下载*: $(format_b $D_RX)
📤 *上传*: $(format_b $D_TX)
↕️ *总计*: $(format_b $D_TOTAL)

📅 *本周期统计*
🗓️ *区间*: \`$START_PERIOD\` ➔ \`$END_PERIOD\`
⏳️ *已用*: $(format_b $USED_BYTES)
⏳️ *剩余*: $(format_b $REMAIN_BYTES)
⌛ *总量*: $(format_b $LIMIT_BYTES)
🔃 *重置*: 每月 $RESET_DAY 号

🎯 *进度*: $BAR $PERCENT%"

# 若设置了总量且接近限制，则附加告警信息
[ "$LIMIT_BYTES" -gt 0 ] && [ "$PERCENT" -ge $((100-ALERT_PERCENT)) ] && MSG="$MSG
⚠️ *告警*: 流量消耗已达 $PERCENT%！"

# 执行 API 推送
curl -s -X POST "$TG_API" -d "chat_id=$CHAT_ID" -d "parse_mode=Markdown" --data-urlencode "text=$MSG" >/dev/null
EOS
    chmod 750 "$SCRIPT_FILE" # 给予执行权限
}

# ---------------- 4. Systemd Timer 配置 ----------------
# 创建后台服务单元和定时器，确保任务每日准时运行
generate_systemd() {
    source "$CONFIG_FILE"
    # 清理旧的定时器
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    
    # 这里的 Service 只是简单触发脚本执行
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS vnStat Telegram Daily Report Service
[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

    # 这里的 Timer 定义了具体时间
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Timer for VPS vnStat Telegram Daily Report
[Timer]
OnCalendar=*-*-* ${DAILY_HOUR}:${DAILY_MIN}:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
}

# ---------------- 5. 主入口逻辑 ----------------
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 $VERSION ---"
    echo "1) 安装/更新配置 (首次安装选此项)"
    echo "2) 仅更新脚本逻辑 (不改 Token/重置日)"
    echo "3) 退出"
    read -rp "请选择 [1-3]: " CH
    case "$CH" in
        1) install_dependencies; generate_config; generate_main_script; generate_systemd; info "安装与配置完成。";;
        2) generate_main_script; generate_systemd; info "代码逻辑更新成功。";;
        *) exit 0;;
    esac
}

main
