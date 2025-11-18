#!/bin/bash
# install_vps_vnstat_telegram.sh
# 一键安装 + 美化 vnStat Telegram 流量统计（动态进度条 + 彩色箭头标记）
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SCRIPT_PATH="/usr/local/bin/vps_vnstat_telegram.sh"
SERVICE_NAME="vps_vnstat_telegram.service"
TIMER_NAME="vps_vnstat_telegram.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err()  { echo -e "[\e[31mERR\e[0m] $*"; }

[ "$(id -u)" -ne 0 ] && { err "请以 root 用户或 sudo 运行"; exit 1; }

# ---------- 系统检测 & 安装依赖 ----------
install_debian() { info "使用 apt 安装依赖"; apt update -y; apt install -y vnstat jq curl bc; }
install_rhel() { info "使用 yum/dnf 安装依赖"; command -v dnf &>/dev/null && dnf install -y vnstat jq curl bc || (yum install -y epel-release; yum install -y vnstat jq curl bc); }
install_fedora() { info "使用 dnf 安装依赖"; dnf install -y vnstat jq curl bc; }
install_alpine() { info "使用 apk 安装依赖"; apk update; apk add vnstat jq curl bc; }
install_openwrt() { info "使用 opkg 安装依赖"; opkg update; opkg install vnstat jq curl bc; }

detect_and_install() {
    [ -f /etc/os-release ] || { err "无法识别系统"; exit 1; }
    . /etc/os-release
    info "检测系统: $ID (like: ${ID_LIKE:-})"
    case "$ID" in
        ubuntu|debian) install_debian ;;
        centos|rhel) install_rhel ;;
        fedora) install_fedora ;;
        alpine) install_alpine ;;
        openwrt) install_openwrt ;;
        *) [[ "$ID_LIKE" == *"debian"* ]] && install_debian || [[ "$ID_LIKE" == *"rhel"* ]] && install_rhel || warn "未知系统，尝试 apt 安装"; install_debian || warn "自动安装失败";;
    esac
}

# ---------- 配置 ----------
create_or_read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "读取配置 $CONFIG_FILE"
        source "$CONFIG_FILE"
        : "${RESET_DAY:?配置文件缺少 RESET_DAY}"
        : "${BOT_TOKEN:?配置文件缺少 BOT_TOKEN}"
        : "${CHAT_ID:?配置文件缺少 CHAT_ID}"
        : "${MONTH_LIMIT_GB:=0}"
        : "${DAILY_HOUR:=0}"
        : "${DAILY_MIN:=0}"
        : "${IFACE:=''}"
        : "${ALERT_PERCENT:=10}"
    else
        info "创建新配置"
        DEFAULT_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | egrep -v "lo|vir|wl|docker|veth" | head -n1 || true)
        [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE="eth0"
        while true; do read -rp "每月流量重置日(1-31): " RESET_DAY; [[ "$RESET_DAY" =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]] && break; echo "请输入1-31"; done
        read -rp "Telegram Bot Token: " BOT_TOKEN
        read -rp "Telegram Chat ID: " CHAT_ID
        while true; do read -rp "月度总流量(GB,0无限): " MONTH_LIMIT_GB; [[ "$MONTH_LIMIT_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] && break; echo "请输入数字"; done
        while true; do read -rp "每日提醒时间-小时(0-23): " DAILY_HOUR; [[ "$DAILY_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] && break; done
        while true; do read -rp "每日提醒时间-分钟(0-59): " DAILY_MIN; [[ "$DAILY_MIN" =~ ^([0-9]|[1-5][0-9])$ ]] && break; done
        read -rp "监控网卡(默认 $DEFAULT_IFACE): " IFACE; IFACE=${IFACE:-$DEFAULT_IFACE}
        read -rp "剩余流量告警百分比(默认10,0不告警): " ALERT_PERCENT; ALERT_PERCENT=${ALERT_PERCENT:-10}

        cat > "$CONFIG_FILE" <<EOF
RESET_DAY=$RESET_DAY
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
MONTH_LIMIT_GB=$MONTH_LIMIT_GB
DAILY_HOUR=$DAILY_HOUR
DAILY_MIN=$DAILY_MIN
IFACE="$IFACE"
ALERT_PERCENT=$ALERT_PERCENT
EOF
        chmod 600 "$CONFIG_FILE"
        info "配置已保存 $CONFIG_FILE"
    fi
}

# ---------- 主脚本 ----------
generate_main_script() {
info "生成主脚本 $SCRIPT_PATH ..."

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

cat > "$SCRIPT_PATH" <<EOSCRIPT
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="$CONFIG_FILE"
STATE_DIR="$STATE_DIR"
STATE_FILE="$STATE_FILE"

source "\$CONFIG_FILE"

MONTH_LIMIT_BYTES=\$(awk -v g="\$MONTH_LIMIT_GB" 'BEGIN{printf("%.0f", g*1024*1024*1024)}')
ALERT_PERCENT=\${ALERT_PERCENT:-10}
IFACE=\${IFACE:-eth0}

TG_API_BASE="https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage"
HOST_NAME=\$(hostname)
VPS_IP=\$(curl -fsS https://api.ipify.org || echo "无法获取")

escape_md(){ local s="\$1"; s="\${s//_/\\_}"; s="\${s//*/\\*}"; s="\${s//#/\\#}"; echo "\$s"; }
format_bytes(){ awk -v b="\$1" 'BEGIN{split("B KB MB GB TB",u," ");i=0;while(b>=1024&&i<4){b/=1024;i++} if(i==0){printf "%d%s",int(b+0.5),u[i+1]}else{printf "%.2f%s",b,u[i+1]}}'; }

get_vnstat_today_bytes(){ local rx tx total; rx=\$(vnstat -i "\$1" --json | jq '.interfaces[0].traffic.day[-1].rx//0'); tx=\$(vnstat -i "\$1" --json | jq '.interfaces[0].traffic.day[-1].tx//0'); total=\$((rx+tx)); echo "\$rx \$tx \$total"; }
get_vnstat_cumulative_bytes(){ vnstat -i "\$1" --json | jq '[.interfaces[0].traffic.day[]?|(.rx+ .tx)]|add//0'; }

init_state_if_missing(){ [ ! -f "\$STATE_FILE" ] && echo "{\"last_snapshot_date\":\"\$(date +%Y-%m-%d)\",\"snapshot_bytes\":\$(get_vnstat_cumulative_bytes "\$IFACE")}" > "\$STATE_FILE" && chmod 600 "\$STATE_FILE"; }
read_snapshot(){ SNAP_DATE=\$(jq -r '.last_snapshot_date // empty' "\$STATE_FILE"); SNAP_BYTES=\$(jq -r '.snapshot_bytes // 0' "\$STATE_FILE"); }
write_snapshot(){ echo "{\"last_snapshot_date\":\"\$(date +%Y-%m-%d)\",\"snapshot_bytes\":\$1}" > "\$STATE_FILE"; chmod 600 "\$STATE_FILE"; }

send_message(){
    local USED=\$1 REMAIN=\$2 PCT=\$3 SNAP_START=\$4 SNAP_END=\$5 TODAY_RX=\$6 TODAY_TX=\$7 TODAY_TOTAL=\$8 WIDTH=20
    if [ "\$PCT" -le 50 ]; then BAR_CHAR="🟩"; elif [ "\$PCT" -le 80 ]; then BAR_CHAR="🟧"; else BAR_CHAR="🟥"; fi
    local FILLED=\$(( PCT*WIDTH/100 )); [ \$FILLED -gt \$WIDTH ] && FILLED=\$WIDTH
    local EMPTY=\$((WIDTH-FILLED))
    local BAR=\$(printf "${BAR_CHAR}%.0s" \$(seq 1 \$FILLED))\$(printf "⬜%.0s" \$(seq 1 \$EMPTY))
    local STATUS="✅"; [ "\$PCT" -ge 90 ] && STATUS="⚠️"
    local TODAY_PCT=0; [ "\$MONTH_LIMIT_BYTES" -gt 0 ] && TODAY_PCT=\$(( TODAY_TOTAL*100/MONTH_LIMIT_BYTES ))
    local TODAY_BAR=\$(printf "🟦%.0s" \$(seq 1 \$((TODAY_PCT*WIDTH/100))))\$(printf "⬜%.0s" \$(seq 1 \$((WIDTH - TODAY_PCT*WIDTH/100))))
    local TODAY_STATUS="✅"; [ "\$TODAY_PCT" -ge 100 ] && TODAY_STATUS="⚠️"

    MSG="📊 *VPS 流量日报*
🖥️ 主机: \$(escape_md "\$HOST_NAME")   🌐 IP: \$(escape_md "\$VPS_IP")
💾 网卡: \$(escape_md "\$IFACE")   ⏰ \$(date +"%Y-%m-%d %H:%M:%S")

🔹 *今日流量*
⬇️ 下载: \${TODAY_RX}GB   ⬆️ 上传: \${TODAY_TX}GB   📦 总计: \${TODAY_TOTAL}GB
📊 进度: \${TODAY_BAR} \${TODAY_PCT}%   ⚡ 状态: \${TODAY_STATUS}

🔸 *本周期流量 (\${SNAP_START} → \${SNAP_END})*
📌 已用: \${USED}GB   剩余: \${REMAIN}GB / 总量 \${MONTH_LIMIT_GB}GB
📊 进度: \${BAR} \${PCT}%   ⚡ 流量状态: \${STATUS}"

    curl -s -X POST "\$TG_API_BASE" \
        -d chat_id="\$CHAT_ID" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=\$MSG" >/dev/null 2>&1
}

main(){
    init_state_if_missing
    read_snapshot
    read DAY_RX DAY_TX DAY_TOTAL < <(get_vnstat_today_bytes "\$IFACE")
    CUR_SUM=\$(get_vnstat_cumulative_bytes "\$IFACE")
    USED_BYTES=\$((CUR_SUM-SNAP_BYTES)); [ \$USED_BYTES -lt 0 ] && USED_BYTES=0
    REMAIN_BYTES=\$((MONTH_LIMIT_BYTES-USED_BYTES)); [ \$REMAIN_BYTES -lt 0 ] && REMAIN_BYTES=0

    USED_GB=\$(awk "BEGIN{printf \"%.2f\", \$USED_BYTES/1024/1024/1024}")
    REMAIN_GB=\$(awk "BEGIN{printf \"%.2f\", \$REMAIN_BYTES/1024/1024/1024}")
    DAY_RX_GB=\$(awk "BEGIN{printf \"%.2f\", \$DAY_RX/1024/1024/1024}")
    DAY_TX_GB=\$(awk "BEGIN{printf \"%.2f\", \$DAY_TX/1024/1024/1024}")
    DAY_TOTAL_GB=\$(awk "BEGIN{printf \"%.2f\", \$DAY_TOTAL/1024/1024/1024}")
    PCT=\$((USED_BYTES*100/MONTH_LIMIT_BYTES)); [ "\$MONTH_LIMIT_BYTES" -le 0 ] && PCT=0

    send_message "\$USED_GB" "\$REMAIN_GB" "\$PCT" "\$SNAP_DATE" "\$(date +%Y-%m-%d)" "\$DAY_RX_GB" "\$DAY_TX_GB" "\$DAY_TOTAL_GB"

    TODAY_DAY=\$(date +%d | sed 's/^0*//')
    [ "\$TODAY_DAY" -eq "\$RESET_DAY" ] && write_snapshot "\$CUR_SUM"
}

main "\$@"
EOSCRIPT

chmod 750 "$SCRIPT_PATH"
info "主脚本生成完成"
}

# ---------- systemd timer ----------
generate_systemd_unit(){
    source "$CONFIG_FILE"
    H=$(printf "%02d" "$DAILY_HOUR")
    M=$(printf "%02d" "$DAILY_MIN")
    ONCAL="*-*-* ${H}:${M}:00"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=VPS vnStat Telegram daily report
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

    cat > "$TIMER_PATH" <<EOF
[Unit]
Description=Daily timer for vps_vnstat_telegram

[Timer]
OnCalendar=$ONCAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$(basename "$TIMER_PATH")" || true
    systemctl start "$(basename "$TIMER_PATH")" || true
    info "systemd timer 已启用"
}

ensure_vnstat_running_and_initialized(){
    command -v vnstat &>/dev/null || return
    vnstat --create -i "$IFACE" 2>/dev/null || true
    vnstat -u -i "$IFACE" 2>/dev/null || true
}

main_install(){
    detect_and_install
    create_or_read_config
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    ensure_vnstat_running_and_initialized
    generate_main_script
    command -v systemctl &>/dev/null && systemctl --version &>/dev/null && generate_systemd_unit || warn "使用 crontab 备选"
    info "安装完成！手动运行: sudo $SCRIPT_PATH"
}

main_install
