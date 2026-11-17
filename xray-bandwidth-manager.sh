#!/usr/bin/env bash
set -Eeuo pipefail

# Xray Bandwidth Manager - Debian 11+, systemd, iproute2, CAKE and IFB.
APP="xray-bandwidth-manager"
VERSION="1.0.0"
BIN="/usr/local/sbin/xray-bandwidth-manager"
CONFIG="/etc/default/xray-bandwidth-manager"
SERVICE="xray-bandwidth-shaping"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
TC="/usr/sbin/tc"
IP="/usr/sbin/ip"
MODPROBE="/usr/sbin/modprobe"

IFACE="eth0"
IFB="ifb0"
OUT_RATE="24"
IN_RATE="24"
ENABLED="1"

die() { echo "错误：$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行：$BIN"; }
load_config() {
    if [[ -f "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG"
    fi
}
valid_rate() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
        awk -v n="$1" 'BEGIN { exit !(n > 0 && n <= 100000) }'
}
valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; }

save_config() {
    install -d -m 755 /etc/default
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
IFACE='$IFACE'
IFB='$IFB'
OUT_RATE='$OUT_RATE'
IN_RATE='$IN_RATE'
ENABLED='$ENABLED'
EOF
    install -o root -g root -m 600 "$tmp" "$CONFIG"
    rm -f "$tmp"
}

check_dependencies() {
    [[ -x "$TC" ]] || die "找不到 tc，请安装 iproute2"
    [[ -x "$IP" ]] || die "找不到 ip"
    [[ -x "$MODPROBE" ]] || die "找不到 modprobe，请安装 kmod"
    command -v systemctl >/dev/null || die "此工具需要 systemd"
    command -v awk >/dev/null || die "缺少 awk"
}

apply_rules() {
    load_config
    [[ "$ENABLED" == "1" ]] || { remove_shaping; return 0; }
    valid_iface "$IFACE" || die "物理网卡名称不合法"
    valid_iface "$IFB" || die "IFB 名称不合法"
    valid_rate "$OUT_RATE" || die "出站速率不合法"
    valid_rate "$IN_RATE" || die "入站速率不合法"
    "$IP" link show dev "$IFACE" >/dev/null 2>&1 || die "网卡 $IFACE 不存在"
    "$MODPROBE" ifb numifbs=1
    "$IP" link show dev "$IFB" >/dev/null 2>&1 || die "IFB $IFB 不存在；请检查 ifb 模块"
    "$IP" link set dev "$IFB" up
    # Delete then add instead of using "qdisc replace": for an existing CAKE
    # instance, replace/change updates the configured rate but can retain
    # avg_peak_bandwidth from the old rate. Recreating CAKE resets that state.
    # This briefly removes the root qdisc and resets its statistics.
    "$TC" qdisc del dev "$IFACE" root 2>/dev/null || true
    "$TC" qdisc add dev "$IFACE" root cake bandwidth "${OUT_RATE}mbit" diffserv3 triple-isolate

    "$TC" qdisc del dev "$IFB" root 2>/dev/null || true
    "$TC" qdisc add dev "$IFB" root cake bandwidth "${IN_RATE}mbit" diffserv3 triple-isolate
    "$TC" qdisc replace dev "$IFACE" clsact
    "$TC" filter del dev "$IFACE" ingress pref 49152 2>/dev/null || true
    "$TC" filter add dev "$IFACE" ingress protocol all pref 49152 \
        matchall action mirred egress redirect dev "$IFB"
}

remove_shaping() {
    load_config
    "$TC" filter del dev "$IFACE" ingress pref 49152 2>/dev/null || true
    # Restores mq, but cannot reconstruct custom qdisc settings from before installation.
    "$TC" qdisc replace dev "$IFACE" root mq 2>/dev/null || true
    "$TC" qdisc del dev "$IFB" root 2>/dev/null || true
}

install_service() {
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Network Bandwidth Shaping (CAKE + IFB)
Wants=network-online.target
After=network-online.target
Before=x-ui.service

[Service]
Type=oneshot
ExecStart=$BIN --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
}

status() {
    load_config
    echo "版本：$VERSION"
    echo "网卡：$IFACE | IFB：$IFB"
    echo "服务器出站限速：${OUT_RATE} Mbps"
    echo "服务器入站限速：${IN_RATE} Mbps"
    echo "配置开关：$([[ "$ENABLED" == 1 ]] && echo 启用 || echo 暂停)"
    echo "开机启动：$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo 未启用)"
    echo "服务状态：$(systemctl is-active "$SERVICE" 2>/dev/null || echo 未运行)"
    echo
    echo "=== 出站 qdisc：$IFACE ==="
    "$TC" -s qdisc show dev "$IFACE" || true
    echo
    echo "=== 入站 qdisc：$IFB ==="
    "$TC" -s qdisc show dev "$IFB" || true
    echo
    echo "=== 入站重定向 ==="
    "$TC" filter show dev "$IFACE" ingress 2>/dev/null || true
}

stats() {
    echo "每 2 秒刷新，按 Ctrl+C 返回。"
    trap 'echo; trap - INT; return 0' INT
    while :; do
        clear
        date
        echo "=== 出站：$IFACE ==="
        "$TC" -s qdisc show dev "$IFACE" | head -n 35
        echo
        echo "=== 入站：$IFB ==="
        "$TC" -s qdisc show dev "$IFB" | head -n 35
        sleep 2
    done
    trap - INT
}

restart_service() {
    install_service
    systemctl restart "$SERVICE"
}

change_rates() {
    load_config
    local out in
    read -rp "服务器出站限速 Mbps [当前 $OUT_RATE]： " out
    read -rp "服务器入站限速 Mbps [当前 $IN_RATE]： " in
    [[ -n "$out" ]] || out="$OUT_RATE"
    [[ -n "$in" ]] || in="$IN_RATE"
    valid_rate "$out" || { echo "出站速率无效"; return 1; }
    valid_rate "$in" || { echo "入站速率无效"; return 1; }
    OUT_RATE="$out"; IN_RATE="$in"; ENABLED=1
    save_config
    restart_service
    echo "已应用：出站 ${OUT_RATE} Mbps，入站 ${IN_RATE} Mbps"
}

change_interface() {
    load_config
    local iface
    read -rp "物理网卡 [当前 $IFACE]： " iface
    [[ -n "$iface" ]] || return 0
    valid_iface "$iface" || { echo "网卡名称无效"; return 1; }
    "$IP" link show dev "$iface" >/dev/null 2>&1 || { echo "网卡不存在"; return 1; }
    IFACE="$iface"
    save_config
    restart_service
}

pause_shaping() {
    load_config; ENABLED=0; save_config
    systemctl restart "$SERVICE"
    echo "已暂停整形（$IFACE 根队列尝试恢复为 mq）。"
}
resume_shaping() {
    load_config; ENABLED=1; save_config
    restart_service
    echo "已恢复整形。"
}

boot_menu() {
    echo "1) 启用开机自动启动"
    echo "2) 禁用开机自动启动（当前规则不变）"
    echo "0) 返回"
    local c
    read -rp "请选择：" c
    case "$c" in
        1) install_service; echo "已启用" ;;
        2) systemctl disable "$SERVICE"; echo "已禁用" ;;
        0) ;;
        *) echo "无效选项" ;;
    esac
}

uninstall_tool() {
    local c
    echo "卸载会删除服务和配置，并尝试移除整形规则。"
    read -rp "输入 REMOVE 确认：" c
    [[ "$c" == "REMOVE" ]] || return 0
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    remove_shaping
    rm -f "$SERVICE_FILE" "$CONFIG" "$BIN"
    systemctl daemon-reload
    echo "已卸载。"
    exit 0
}

menu() {
    while :; do
        load_config
        clear 2>/dev/null || true
        echo "=========================================="
        echo "       Xray 双向带宽均衡管理工具"
        echo "                 v$VERSION"
        echo "=========================================="
        echo "网卡：$IFACE    IFB：$IFB"
        echo "出站：${OUT_RATE} Mbps    入站：${IN_RATE} Mbps"
        echo "整形：$([[ "$ENABLED" == 1 ]] && echo 开启 || echo 暂停)"
        echo "开机启动：$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo 未启用)"
        echo "------------------------------------------"
        echo "1. 应用当前配置"
        echo "2. 修改双向限速"
        echo "3. 查看状态与统计"
        echo "4. 实时统计（2 秒刷新）"
        echo "5. 暂停带宽整形"
        echo "6. 恢复带宽整形"
        echo "7. 设置开机启动"
        echo "8. 修改物理网卡"
        echo "9. 重启整形服务"
        echo "U. 卸载管理工具"
        echo "0. 退出"
        echo
        local choice
        read -rp "请选择操作：" choice
        case "$choice" in
            1) load_config; ENABLED=1; save_config; restart_service ;;
            2) change_rates ;;
            3) status ;;
            4) stats ;;
            5) pause_shaping ;;
            6) resume_shaping ;;
            7) boot_menu ;;
            8) change_interface ;;
            9) systemctl restart "$SERVICE"; echo "服务已重启" ;;
            U|u) uninstall_tool ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
        echo
        read -rp "按 Enter 返回菜单..." _
    done
}

main() {
    need_root
    check_dependencies

    # Allow running the downloaded script from any directory. Install a stable
    # copy at BIN so the systemd unit can call it on future boots.
    local invoked_path
    invoked_path="$(readlink -f "$0")"
    if [[ "$invoked_path" != "$BIN" ]]; then
        install -D -o root -g root -m 0755 "$invoked_path" "$BIN"
        exec "$BIN" "$@"
    fi

    if [[ "${1:-}" == "--apply" ]]; then
        load_config
        apply_rules
        exit 0
    fi

    [[ -f "$CONFIG" ]] || save_config
    install_service
    menu
}
main "$@"
