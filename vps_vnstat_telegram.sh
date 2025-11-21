#!/bin/bash
# install_vps_vnstat.sh
# VPS vnStat Telegram 流量日报脚本 (已修复 KiB 转换、JQ 路径和指定日期查询)
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
SCRIPT_FILE="/usr/local/bin/vps_vnstat_telegram.sh"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_FILE="/etc/systemd/system/vps_vnstat_telegram.service"
TIMER_FILE="/etc/systemd/system/vps_vnstat_telegram.timer"

info() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR\e[0m] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 用户运行。"
    exit 1
fi

# 安装依赖
install_dependencies() {
    info "开始安装依赖: vnstat, jq, curl, bc..."
    if [ -f /etc/debian_version ]; then
        apt update -y
        apt install -y vnstat jq curl bc
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache vnstat jq curl bc
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        if command -v dnf &>/dev/null; then
            dnf install -y vnstat jq curl bc
        else
            yum install -y epel-release
            yum install -y vnstat jq curl bc
        fi
    else
        warn "未识别系统，请确保已安装 vnstat jq curl bc"
    fi
    info "依赖安装完成。"
}

# 生成配置
generate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        info "配置文件已存在：$CONFIG_FILE，跳过配置生成。"
        return
    fi
    info "开始配置脚本参数..."
    read -rp "请输入每月流量重置日 (1-31, 默认1): " RESET_DAY
    RESET_DAY=${RESET_DAY:-1}
    read -rp "请输入 Telegram Bot Token: " BOT_TOKEN
    read -rp "请输入 Telegram Chat ID: " CHAT_ID
    read -rp "请输入每月流量总量 (GB, 0 不限制, 默认0): " MONTH_LIMIT_GB
    MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}

    # 默认每日提醒 00:30。建议修改为 02:00 或更晚以确保 vnstat 数据更新。
    read -rp "请输入每日提醒小时 (0-23, 建议02或03, 默认0): " DAILY_HOUR
    DAILY_HOUR=${DAILY_HOUR:-0}

    read -rp "请输入每日提醒分钟 (0-59, 默认30): " DAILY_MIN
    DAILY_MIN=${DAILY_MIN:-30}

    DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|vir|wl|docker|veth" | head -n1)
    read -rp "请输入监控网卡 (默认 $DEFAULT_IFACE): " IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    read -rp "请输入流量告警阈值百分比 (默认10): " ALERT_PERCENT
    ALERT_PERCENT=${ALERT_PERCENT:-10}

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
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
    info "配置已保存：$CONFIG_FILE"
}

# 生成主脚本 (已包含所有修复和新功能)
generate_main_script() {
    cat > "$SCRIPT_FILE" <<'EOS'
#!/bin/bash
# vps_vnstat_telegram.sh
# 修复 KiB -> Bytes 转换问题, JQ 路径 (days), 支持命令行传入指定日期 (格式 YYYY-MM-DD)
set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/vps_vnstat_config.conf"
STATE_DIR="/var/lib/vps_vnstat_telegram"
STATE_FILE="$STATE_DIR/state.json"
DEBUG_LOG="/tmp/vps_vnstat_debug.log"

# vnStat JSON V1.15 通常使用 KiB 作为单位。
KIB_TO_BYTES=1024

# --- 调试函数 ---
debug_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*" >> "$DEBUG_LOG"
}
# --- 调试函数结束 ---


if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件缺失：$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# --- 参数解析和日期确定 ---
TARGET_DATE_STR=""
MODE="Daily Report"

if [ $# -gt 0 ]; then
    # 命令行传入了日期参数
    TARGET_DATE_STR="$1"
    MODE="Specific Date Report"
    
    # 检查日期格式是否有效
    if ! date -d "$TARGET_DATE_STR" +%Y-%m-%d &>/dev/null; then
        debug_log "无效日期格式：$TARGET_DATE_STR。使用昨日日期。"
        TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')
        MODE="Daily Report (Fallback)"
    else
        debug_log "接收到指定日期参数: $TARGET_DATE_STR"
    fi
else
    # 默认运行：统计昨日
    TARGET_DATE_STR=$(date -d "yesterday" '+%Y-%m-%d')
fi

# 将目标日期解析为 vnstat JSON 匹配所需的 Y/M/D
TARGET_Y=$(date -d "$TARGET_DATE_STR" '+%Y')
TARGET_M=$((10#$(date -d "$TARGET_DATE_STR" '+%m'))) # 强制十进制
TARGET_D=$((10#$(date -d "$TARGET_DATE_STR" '+%d'))) # 强制十进制
# --- 日期确定结束 ---


# --- 检查是否需要月度重置流量快照 (仅在非指定日期模式下执行) ---
if [ "$MODE" != "Specific Date Report" ]; then
    CURRENT_DAY=$(date +%d)
    CURRENT_DAY=$((10#$CURRENT_DAY)) 
    RESET_DAY=${RESET_DAY:-1} 

    if [ -f "$STATE_FILE" ]; then
        LAST_SNAP_DATE=$(jq -r '.last_snapshot_date // "1970-01-01"' "$STATE_FILE")
        LAST_SNAP_DAY=$(date -d "$LAST_SNAP_DATE" +%d)
        LAST_SNAP_DAY=$((10#$LAST_SNAP_DAY))
    else
        LAST_SNAP_DAY=0 # 状态文件不存在，强制首次快照
    fi

    # 检查是否到了重置日，并且今天还没有重置过
    if [ "$CURRENT_DAY" -eq "$RESET_DAY" ] && [ "$CURRENT_DAY" -ne "$LAST_SNAP_DAY" ]; then
        debug_log "触发月度重置逻辑 (Reset Day: $RESET_DAY)" 
        # 获取当前的 vnstat 总流量 (KiB)
        # FIX: 使用 .days
        CUR_SUM_KIB=$(vnstat -i "$IFACE" --json | jq '[.interfaces[0].traffic.days[]? | (.rx + .tx)] | add // 0')
        # 转换为 Bytes
        CUR_SUM=$((CUR_SUM_KIB * KIB_TO_BYTES))
        NEW_SNAP_DATE=$(date +%Y-%m-%d)
        
        # 写入新的状态文件
        echo "{\"last_snapshot_date\":\"$NEW_SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
        debug_log "快照已更新为 $CUR_SUM 字节，日期 $NEW_SNAP_DATE"
    fi
fi
# --- 月度重置逻辑结束 ---


IFACE=${IFACE:-eth0}
MONTH_LIMIT_GB=${MONTH_LIMIT_GB:-0}
ALERT_PERCENT=${ALERT_PERCENT:-10}

TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
HOST=$(hostname)
IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "未知")

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

format_bytes() {
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{split("B KB MB GB TB", u, " ");i=0; while(b>=1024 && i<4){b/=1024;i++} printf "%.2f%s",b,u[i+1]}'
}

# --- 周期流量计算 (仅在非指定日期模式下计算并报告) ---
if [ "$MODE" != "Specific Date Report" ]; then
    if [ -f "$STATE_FILE" ]; then
        # SNAP_BYTES 存储的是 Bytes
        SNAP_BYTES=$(jq -r '.snapshot_bytes // 0' "$STATE_FILE")
        SNAP_DATE=$(jq -r '.last_snapshot_date // empty' "$STATE_FILE")
    else
        # 状态文件不存在，创建初始快照
        SNAP_BYTES=0
        SNAP_DATE=$(date +%Y-%m-%d)
        # FIX: 使用 .days
        CUR_SUM_KIB=$(vnstat -i "$IFACE" --json | jq '[.interfaces[0].traffic.days[]? | (.rx + .tx)] | add // 0')
        CUR_SUM=$((CUR_SUM_KIB * KIB_TO_BYTES))
        echo "{\"last_snapshot_date\":\"$SNAP_DATE\",\"snapshot_bytes\":$CUR_SUM}" > "$STATE_FILE"
        SNAP_BYTES=$CUR_SUM 
    fi

    DAY_JSON=$(vnstat -i "$IFACE" --json || echo '{}')
    DAY_JSON=${DAY_JSON:-'{}'}

    # 计算总和
    # FIX: 使用 .days
    CUR_SUM_KIB=$(echo "$DAY_JSON" | jq '[.interfaces[0].traffic.days[]? | (.rx + .tx)] | add // 0')
    CUR_SUM=$((CUR_SUM_KIB * KIB_TO_BYTES)) # KiB -> Bytes 转换

    USED_BYTES=$((CUR_SUM - SNAP_BYTES))
    [ "$USED_BYTES" -lt 0 ] && USED_BYTES=0

    MONTH_LIMIT_BYTES=$(awk -v g="$MONTH_LIMIT_GB" 'BEGIN{printf "%.0f",g*1024*1024*1024}')
    [ "$MONTH_LIMIT_BYTES" -le 0 ] && REMAIN_BYTES=0 || REMAIN_BYTES=$((MONTH_LIMIT_BYTES - USED_BYTES))
    [ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0

    PERCENT=0
    [ "$MONTH_LIMIT_BYTES" -gt 0 ] && PERCENT=$((USED_BYTES*100/MONTH_LIMIT_BYTES))
    BAR_LEN=10
    FILLED=$((PERCENT*BAR_LEN/100))
    BAR=""
    for ((i=0;i<BAR_LEN;i++)); do
        if [ "$i" -lt "$FILLED" ]; then
            if [ "$PERCENT" -lt 70 ]; then BAR+="🟩"
            elif [ "$PERCENT" -lt 90 ]; then BAR+="🟨"
            else BAR+="🟥"
            fi
        else
            BAR+="⬜️"
        fi
    done
fi


DAY_RX_KIB=0
DAY_TX_KIB=0

DAY_JSON=$(vnstat -i "$IFACE" --json || echo '{}')
DAY_JSON=${DAY_JSON:-'{}'}


debug_log "--- 开始提取指定日期/昨日流量 ($TARGET_DATE_STR) ---"
debug_log "日期参数: Y=$TARGET_Y, M=$TARGET_M, D=$TARGET_D"

# --- 提取目标日期的流量 (KiB) ---
# FIX: 使用 .days
DAY_VALUES_KIB=$(echo "$DAY_JSON" | jq -r \
  --argjson y "$TARGET_Y" \
  --argjson m "$TARGET_M" \
  --argjson d "$TARGET_D" '
  .interfaces[0].traffic.days // []
  | map(select(.date.year == $y
               and .date.month == $m
               and .date.day == $d))
  | if length>0 then
      "\(.[-1].rx // 0) \(.[-1].tx // 0)"
    else "0 0" end
')
DAY_VALUES_KIB=${DAY_VALUES_KIB:-"0 0"}

debug_log "jq 提取结果 (KiB): $DAY_VALUES_KIB" 

# 分割 KiB 值
IFS=' ' read -r DAY_RX_KIB DAY_TX_KIB <<< "$DAY_VALUES_KIB"

# 转换为 Bytes
DAY_RX=$((DAY_RX_KIB * KIB_TO_BYTES))
DAY_TX=$((DAY_TX_KIB * KIB_TO_BYTES))
DAY_TOTAL=$((DAY_RX + DAY_TX))

debug_log "计算后的流量 (bytes): RX=$DAY_RX, TX=$DAY_TX, TOTAL=$DAY_TOTAL" 

# --- 消息模板 ---
if [ "$MODE" == "Specific Date Report" ]; then
    MSG="📊 VPS 指定日期流量查询

🖥️ 主机: $HOST
🌐 IP: $IP
💾 网卡: $IFACE
⏰ 查询时间: $(date '+%Y-%m-%d %H:%M:%S')

🔹 目标日期流量 ($TARGET_DATE_STR)
⬇️ 下载: $(format_bytes $DAY_RX)   ⬆️ 上传: $(format_bytes $DAY_TX)   📦 总计: $(format_bytes $DAY_TOTAL)"
else
    # 每日/昨日报告模板
    MSG="📊 VPS 流量日报

🖥️ 主机: $HOST
🌐 IP: $IP
💾 网卡: $IFACE
⏰ 时间: $(date '+%Y-%m-%d %H:%M:%S')

🔹 昨日流量 ($TARGET_DATE_STR)
⬇️ 下载: $(format_bytes $DAY_RX)   ⬆️ 上传: $(format_bytes $DAY_TX)   📦 总计: $(format_bytes $DAY_TOTAL)

🔸 本周期流量 (自 $SNAP_DATE 起)
📌 已用: $(format_bytes $USED_BYTES)   剩余: $(format_bytes $REMAIN_BYTES) / 总量: $(format_bytes $MONTH_LIMIT_BYTES)
📊 进度: $BAR $PERCENT%"
    
    # 仅在每日报告中加入告警
    if [ "$MONTH_LIMIT_BYTES" -gt 0 ] && [ "$ALERT_PERCENT" -gt 0 ]; then
        REMAIN_PERCENT=0
        [ "$MONTH_LIMIT_BYTES" -gt 0 ] && REMAIN_PERCENT=$((REMAIN_BYTES*100/MONTH_LIMIT_BYTES))
        
        if [ "$REMAIN_PERCENT" -le "$ALERT_PERCENT" ]; then
            MSG="$MSG
⚠️ 流量告警：剩余 $REMAIN_PERCENT% (≤ $ALERT_PERCENT%)"
        fi
    fi
fi


curl -s -X POST "$TG_API" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$MSG" >/dev/null 2>&1
EOS

    chmod 750 "$SCRIPT_FILE"
    info "主脚本已更新，新增了命令行指定日期查询功能。"
}

# --------------------------------------------------------
# 以下是完整的安装/卸载/主菜单代码
# --------------------------------------------------------

# 生成 systemd timer
generate_systemd() {
    # 确保配置已加载
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" || { err "无法加载配置，无法生成 systemd 文件"; exit 1; }

    # 停用并删除旧 timer
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true

    # service
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS vnStat Telegram Daily Report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

    # timer
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily timer for VPS vnStat Telegram Report

[Timer]
OnCalendar=*-*-* ${DAILY_HOUR}:${DAILY_MIN}:00
Persistent=true
Unit=vps_vnstat_telegram.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_vnstat_telegram.timer
    info "systemd timer 已启用，配置为 ${DAILY_HOUR}:${DAILY_MIN} 运行。"
}

# 卸载
uninstall_all() {
    info "开始卸载 vps_vnstat_telegram..."
    systemctl disable --now vps_vnstat_telegram.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    rm -f "/tmp/vps_vnstat_debug.log"
    systemctl daemon-reload
    info "卸载完成。"
}

# 主菜单
main() {
    echo "--- VPS vnStat Telegram 流量日报脚本 ---"
    echo "请选择操作："
    echo "1) 安装 (自动安装依赖、配置、设置定时任务)"
    echo "2) 卸载 (删除所有文件和定时任务)"
    echo "3) 退出"
    read -rp "请输入数字: " CHOICE
    case "$CHOICE" in
        1)
            install_dependencies
            generate_config
            generate_main_script
            generate_systemd
            info "所有安装步骤完成。定时任务已启用。"
            info "调试日志文件位于 /tmp/vps_vnstat_debug.log"
            info "要查询指定日期流量，请运行：/usr/local/bin/vps_vnstat_telegram.sh YYYY-MM-DD"
            ;;
        2)
            uninstall_all
            ;;
        3)
            info "操作已取消。"
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

main
