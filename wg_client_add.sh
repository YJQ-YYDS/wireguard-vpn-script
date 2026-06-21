#!/bin/bash
# ================================================
# WireGuard 客户端配置一键生成脚本
# 用法: sudo bash wg_client_add.sh
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

# 检查 root
if [ "$EUID" -ne 0 ]; then
    error "请以 root 权限运行此脚本 (sudo bash $0)"
fi

clear
info "WireGuard 客户端配置生成工具"
info "本脚本将帮您生成新的客户端密钥和配置文件，并自动添加到服务端。"

# 检查服务端是否已配置
if [ ! -f /etc/wireguard/wg0.conf ]; then
    error "未找到服务端配置文件 /etc/wireguard/wg0.conf，请先运行服务端部署脚本。"
fi
if [ ! -f /etc/wireguard/server_public.key ]; then
    error "未找到服务器公钥文件 /etc/wireguard/server_public.key，请先运行服务端部署脚本。"
fi

# 读取服务器公钥
SERVER_PUB=$(cat /etc/wireguard/server_public.key)
info "已读取服务器公钥: $SERVER_PUB"

# ------------------------------------------------------------------
# 读取服务端 IP 用于推荐客户端 IP
step_start "读取服务端 IP 以推荐客户端地址"
SERVER_ADDR=$(grep -E '^Address\s*=' /etc/wireguard/wg0.conf | awk '{print $3}' | head -n1)
if [ -z "$SERVER_ADDR" ]; then
    warn "无法读取服务端 IP，将使用默认推荐 10.0.0.2/24"
    RECOMMEND_IP="10.0.0.2/24"
else
    # 解析 IP 和掩码
    SERVER_IP_ONLY=$(echo $SERVER_ADDR | cut -d'/' -f1)
    SERVER_MASK=$(echo $SERVER_ADDR | cut -d'/' -f2)
    IP_PREFIX=$(echo $SERVER_IP_ONLY | cut -d'.' -f1-3)
    IP_LAST=$(echo $SERVER_IP_ONLY | cut -d'.' -f4)
    CLIENT_LAST=$((IP_LAST + 1))
    RECOMMEND_IP="${IP_PREFIX}.${CLIENT_LAST}/${SERVER_MASK}"
    
    # 检查该 IP 是否已被使用（扫描现有 Peer 的 AllowedIPs，但注意我们现在将 AllowedIPs 设为 0.0.0.0/0，所以不再用 AllowedIPs 判断，改用注释或单独记录？我们可以在添加 Peer 时注释掉 IP，但为简单，仍用 AllowedIPs 检查旧配置，因为老版本可能使用了具体 IP）
    # 这里为了兼容，检查现有配置中是否存在相同 IP 的注释或 AllowedIPs
    if grep -q "AllowedIPs = ${IP_PREFIX}.${CLIENT_LAST}/${SERVER_MASK}" /etc/wireguard/wg0.conf; then
        warn "推荐 IP $RECOMMEND_IP 已被占用，尝试递增..."
        while grep -q "AllowedIPs = ${IP_PREFIX}.${CLIENT_LAST}/${SERVER_MASK}" /etc/wireguard/wg0.conf; do
            CLIENT_LAST=$((CLIENT_LAST + 1))
        done
        RECOMMEND_IP="${IP_PREFIX}.${CLIENT_LAST}/${SERVER_MASK}"
        info "找到可用 IP: $RECOMMEND_IP"
    fi
fi
info "推荐客户端 IP: $RECOMMEND_IP"
step_end "读取服务端 IP 完成"

# ------------------------------------------------------------------
# 1. 交互输入客户端名称
step_start "输入客户端名称（用于标识）"
while true; do
    read -p "请输入客户端名称 (例如: openwrt-sg01、openwrt-sg02): " CLIENT_NAME
    if [[ -z "$CLIENT_NAME" ]]; then
        warn "名称不能为空，请重新输入。"
        continue
    fi
    if grep -q "# $CLIENT_NAME" /etc/wireguard/wg0.conf; then
        warn "已存在名为 $CLIENT_NAME 的 Peer，请使用不同名称。"
        continue
    fi
    echo -e "您输入的客户端名称: ${YELLOW}$CLIENT_NAME${NC}"
    read -p "确认使用此名称？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
    fi
done
step_end "客户端名称确认: $CLIENT_NAME"

# ------------------------------------------------------------------
# 2. 交互输入客户端虚拟 IP（默认使用推荐值）
step_start "配置客户端虚拟 IP 地址"
while true; do
    read -p "请输入客户端 VPN 虚拟 IP (默认推荐: $RECOMMEND_IP，直接回车使用): " CLIENT_IP
    if [[ -z "$CLIENT_IP" ]]; then
        CLIENT_IP="$RECOMMEND_IP"
        info "使用推荐 IP: $CLIENT_IP"
    fi
    # 检查 IP 是否已被其他 Peer 使用（仅检查旧式配置，新式配置 AllowedIPs=0.0.0.0/0 我们无法检测，但仍保留检查）
    if grep -q "AllowedIPs = $CLIENT_IP" /etc/wireguard/wg0.conf; then
        warn "IP $CLIENT_IP 已被其他 Peer 使用，请重新输入。"
        continue
    fi
    echo -e "您输入的客户端 IP: ${YELLOW}$CLIENT_IP${NC}"
    read -p "确认使用此 IP？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
    fi
done
step_end "客户端虚拟 IP 已设定: $CLIENT_IP"

# ------------------------------------------------------------------
# 3. 生成客户端密钥对
step_start "生成客户端密钥对"
mkdir -p /root/wireguard
cd /root/wireguard
umask 077
wg genkey | tee ${CLIENT_NAME}_private.key | wg pubkey | tee ${CLIENT_NAME}_public.key > /dev/null
CLIENT_PUB=$(cat ${CLIENT_NAME}_public.key)
CLIENT_PRIV=$(cat ${CLIENT_NAME}_private.key)
info "客户端私钥已保存: /root/wireguard/${CLIENT_NAME}_private.key"
info "客户端公钥已保存: /root/wireguard/${CLIENT_NAME}_public.key"
info "客户端公钥: $CLIENT_PUB"
step_end "生成客户端密钥对"

# ------------------------------------------------------------------
# 4. 追加 Peer 到服务端 wg0.conf（AllowedIPs 固定为 0.0.0.0/0）
step_start "将客户端添加到服务端配置 (wg0.conf)"
cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
cat >> /etc/wireguard/wg0.conf <<EOF

# $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
info "已向 /etc/wireguard/wg0.conf 追加以下内容："
tail -n 5 /etc/wireguard/wg0.conf
step_end "添加客户端到服务端"

# ------------------------------------------------------------------
# 5. 获取服务器公网 IP 和端口（交互）
step_start "配置服务器公网端点 (Endpoint)"
DEFAULT_ENDPOINT_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")
DEFAULT_ENDPOINT_PORT="51820"
while true; do
    read -p "请输入服务器的公网 IP 或域名 [默认: $DEFAULT_ENDPOINT_IP]: " SERVER_ENDPOINT
    SERVER_ENDPOINT=${SERVER_ENDPOINT:-$DEFAULT_ENDPOINT_IP}
    read -p "请输入 WireGuard 端口 [默认: $DEFAULT_ENDPOINT_PORT]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-$DEFAULT_ENDPOINT_PORT}
    echo -e "您输入的 Endpoint: ${YELLOW}${SERVER_ENDPOINT}:${SERVER_PORT}${NC}"
    read -p "确认？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
    fi
done
step_end "服务器端点确认: ${SERVER_ENDPOINT}:${SERVER_PORT}"

# ------------------------------------------------------------------
# 6. 生成客户端配置文件
step_start "生成客户端配置文件"
CLIENT_CONF="/root/wireguard/${CLIENT_NAME}.conf"
cat > $CLIENT_CONF <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_IP
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
info "客户端配置文件已生成: $CLIENT_CONF"
echo -e "\n${GREEN}配置文件内容：${NC}"
cat $CLIENT_CONF
step_end "生成客户端配置文件"

# ------------------------------------------------------------------
# 7. 提示重启服务
step_start "服务生效提示"
echo -e "\n${YELLOW}为使新客户端生效，您需要重启 WireGuard 服务：${NC}"
echo "    systemctl restart wg-quick@wg0"
read -p "是否现在立即重启服务？(y/n): " RESTART_NOW
if [[ "$RESTART_NOW" =~ ^[Yy]$ ]]; then
    systemctl restart wg-quick@wg0
    info "服务已重启，当前状态："
    systemctl status wg-quick@wg0 --no-pager | head -n 5
    echo -e "\nWireGuard 接口状态："
    wg show
else
    info "请稍后手动执行重启命令: systemctl restart wg-quick@wg0"
fi
step_end "服务生效提示"

info "========== 客户端配置完成 =========="
info "客户端配置文件: $CLIENT_CONF"
info "请将该文件通过安全方式传输给客户端设备，并导入 WireGuard 客户端使用。"
info "客户端私钥位置: /root/wireguard/${CLIENT_NAME}_private.key (请妥善保管)"
