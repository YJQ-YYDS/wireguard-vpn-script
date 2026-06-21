#!/bin/bash
# ================================================
# WireGuard 服务端一键部署脚本 (Ubuntu 24.04)
# 支持重复执行，自动跳过已完成步骤
# 用法: sudo bash wg_server_setup.sh
# ================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step_start() { echo -e "\n${BLUE}>>> 开始: $1${NC}"; }
step_end() { echo -e "${BLUE}<<< 完成: $1${NC}\n"; }
skip_step() { echo -e "${YELLOW}>>> 跳过: $1 (已完成)${NC}"; }

# 检查 root
if [ "$EUID" -ne 0 ]; then
    error "请以 root 权限运行此脚本 (sudo bash $0)"
fi

# ---------- 状态检查函数 ----------
check_wireguard_installed() {
    command -v wg &> /dev/null
}

check_ip_forward() {
    sysctl -n net.ipv4.ip_forward | grep -q "1"
}

check_server_keys() {
    [ -f /etc/wireguard/server_private.key ] && [ -f /etc/wireguard/server_public.key ]
}

check_server_config() {
    [ -f /etc/wireguard/wg0.conf ] && grep -q "^PrivateKey" /etc/wireguard/wg0.conf
}

check_ufw_ports() {
    if command -v ufw &> /dev/null; then
        ufw status | grep -q "51820/udp" && ufw status | grep -q "22/tcp"
    else
        return 1  # 如果 ufw 未安装，视为未配置
    fi
}

check_ufw_forward() {
    if command -v ufw &> /dev/null; then
        grep -q 'DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw
    else
        return 1
    fi
}

check_service_enabled() {
    systemctl is-enabled wg-quick@wg0 &> /dev/null
}

check_service_active() {
    systemctl is-active wg-quick@wg0 &> /dev/null
}

# 全部完成检查
all_done() {
    check_wireguard_installed && \
    check_ip_forward && \
    check_server_keys && \
    check_server_config && \
    check_ufw_ports && \
    check_ufw_forward && \
    check_service_enabled && \
    check_service_active
}

# 如果全部完成，直接提示退出
if all_done; then
    echo -e "\n${GREEN}所有 WireGuard 服务端组件已部署完成，无需重复执行。${NC}"
    echo -e "当前服务状态："
    systemctl status wg-quick@wg0 --no-pager | head -n 5
    wg show
    exit 0
fi

clear
info "欢迎使用 WireGuard 服务端一键部署脚本 (支持重复执行)"
info "将自动检查并跳过已完成步骤，执行未完成部分。"

# ------------------------------------------------------------------
# 1. 安装 WireGuard
if check_wireguard_installed; then
    skip_step "安装 WireGuard"
else
    step_start "安装 WireGuard 和 resolvconf"
    apt update -qq || error "更新软件源失败，请检查网络或手动 apt update"
    apt install wireguard resolvconf -y -qq || error "安装 WireGuard 失败，请检查网络或手动安装"
    if command -v wg &> /dev/null; then
        info "WireGuard 安装成功，版本: $(wg --version 2>&1 | head -n1)"
    else
        error "安装后 wg 命令仍不可用，请手动排查"
    fi
    step_end "安装 WireGuard 和 resolvconf"
fi

# ------------------------------------------------------------------
# 2. 开启 IP 转发
if check_ip_forward; then
    skip_step "开启 IPv4 转发"
else
    step_start "开启 IPv4 转发（永久生效）"
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p > /dev/null || error "sysctl -p 执行失败，请检查 /etc/sysctl.conf 语法"
    if [ "$(sysctl -n net.ipv4.ip_forward)" -eq 1 ]; then
        info "IPv4 转发已成功开启"
    else
        error "IPv4 转发开启未生效，请手动检查"
    fi
    step_end "开启 IPv4 转发"
fi

# ------------------------------------------------------------------
# 3. 生成服务器密钥对
if check_server_keys; then
    skip_step "生成服务器密钥对"
else
    step_start "生成服务器密钥对"
    mkdir -p /etc/wireguard || error "无法创建 /etc/wireguard 目录"
    cd /etc/wireguard
    umask 077
    wg genkey | tee server_private.key | wg pubkey | tee server_public.key > /dev/null || error "生成密钥失败，请检查 wg 命令是否可用"
    info "服务器私钥: $(cat server_private.key)"
    info "服务器公钥: $(cat server_public.key)"
    step_end "生成服务器密钥对"
fi

# ------------------------------------------------------------------
# 4. 交互输入服务器虚拟 IP（允许重输，提示使用奇数）
step_start "配置服务器虚拟 IP 地址"
# 如果配置文件已存在且包含 Address，则读取当前值作为默认，避免重复询问
CURRENT_SERVER_IP=""
if check_server_config; then
    CURRENT_SERVER_IP=$(grep -E '^Address\s*=' /etc/wireguard/wg0.conf | awk '{print $3}' | head -n1)
    if [ -n "$CURRENT_SERVER_IP" ]; then
        warn "检测到已有配置中的 IP: $CURRENT_SERVER_IP，将使用此值"
        SERVER_IP="$CURRENT_SERVER_IP"
    fi
fi

if [ -z "$SERVER_IP" ]; then
    while true; do
        read -p "请输入服务器的 VPN 虚拟 IP (配置奇数，例如 100.98.1.161/30): " SERVER_IP
        if [[ -z "$SERVER_IP" ]]; then
            warn "输入不能为空，请重新输入。"
            continue
        fi
        echo -e "您输入的 IP 为: ${YELLOW}$SERVER_IP${NC}"
        read -p "确认使用此 IP？(y/n，输入 n 重新输入): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done
else
    info "使用现有配置中的 IP: $SERVER_IP"
fi
info "服务器虚拟 IP 已设定为: $SERVER_IP"
step_end "配置服务器虚拟 IP 地址"

# ------------------------------------------------------------------
# 5. 自动探测公网网卡
step_start "探测公网网卡（用于 MASQUERADE）"
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    warn "未能自动探测默认网卡，将使用 'eth0'，请根据实际情况修改配置。"
    INTERFACE="eth0"
else
    info "探测到默认网卡: $INTERFACE"
fi
step_end "探测公网网卡"

# ------------------------------------------------------------------
# 6. 创建服务器配置文件 wg0.conf
if check_server_config && grep -q "PostUp.*$INTERFACE" /etc/wireguard/wg0.conf; then
    skip_step "创建 /etc/wireguard/wg0.conf (已存在且网卡匹配)"
else
    step_start "创建 /etc/wireguard/wg0.conf"
    PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $SERVER_IP
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF
    info "配置文件已创建，内容如下："
    cat /etc/wireguard/wg0.conf
    step_end "创建 /etc/wireguard/wg0.conf"
fi

# ------------------------------------------------------------------
# 7. 配置防火墙（UFW）并显示规则
if check_ufw_ports && check_ufw_forward; then
    skip_step "配置 UFW 防火墙 (规则已存在)"
else
    step_start "配置 UFW 防火墙"
    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp > /dev/null 2>&1 || warn "添加 22/tcp 规则失败，可能已存在"
        ufw allow 51820/udp > /dev/null 2>&1 || warn "添加 51820/udp 规则失败，可能已存在"
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw
        ufw reload > /dev/null 2>&1 || error "ufw reload 失败，请检查 ufw 状态"
        info "UFW 已放行端口: 22/tcp, 51820/udp，并允许转发。"
        echo -e "\n${GREEN}当前 UFW 规则：${NC}"
        ufw status verbose
    else
        warn "UFW 未安装，跳过防火墙配置。请手动确保端口 22/tcp 和 51820/udp 已放行。"
    fi
    step_end "配置 UFW 防火墙"
fi

# 云主机安全组提示（始终显示）
echo -e "\n${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}   【重要】如果您使用的是云主机（如 AWS、阿里云等）  ${NC}"
echo -e "${RED}   请在安全组中添加入方向规则：                       ${NC}"
echo -e "${RED}     协议: UDP，端口: 51820，来源: 0.0.0.0/0        ${NC}"
echo -e "${RED}   否则客户端将无法连接！                             ${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}\n"

# ------------------------------------------------------------------
# 8. 启动并启用 WireGuard 服务
if check_service_enabled && check_service_active; then
    skip_step "设置开机自启并启动 WireGuard 服务 (服务已启用并运行)"
else
    step_start "设置开机自启并启动 WireGuard 服务"
    systemctl enable wg-quick@wg0 > /dev/null 2>&1 || error "systemctl enable 失败"
    systemctl start wg-quick@wg0 || error "systemctl start 失败，请检查配置 (journalctl -u wg-quick@wg0)"
    sleep 2
    if systemctl is-active --quiet wg-quick@wg0; then
        info "✅ 服务已成功启动，状态: active (running)"
    else
        error "服务启动异常，请查看日志: journalctl -u wg-quick@wg0"
    fi
    echo -e "\n${GREEN}服务状态：${NC}"
    systemctl status wg-quick@wg0 --no-pager | head -n 10
    step_end "设置开机自启并启动 WireGuard 服务"
fi

# 显示 wg 接口信息
echo -e "\n${GREEN}当前 WireGuard 接口状态：${NC}"
wg show

# 最终总结（再次强调安全组）
echo -e "\n${YELLOW}========== 服务端部署完成 ==========${NC}"
info "服务器私钥: $(cat /etc/wireguard/server_private.key)"
info "服务器公钥: $(cat /etc/wireguard/server_public.key)"
info "配置文件: /etc/wireguard/wg0.conf"
echo -e "\n${RED}【再次提醒】云主机请务必添加安全组规则：UDP 51820${NC}"
info "请保存好以上密钥，后续添加客户端时需要用到服务器公钥。"
