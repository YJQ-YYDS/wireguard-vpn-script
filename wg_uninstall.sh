#!/bin/bash
# ================================================
# WireGuard 一键卸载清理脚本（优化锁等待）
# 用法: sudo bash wg_uninstall.sh
# 警告: 此脚本将彻底删除 WireGuard 配置、密钥和软件包！
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

if [ "$EUID" -ne 0 ]; then
    error "请以 root 权限运行此脚本 (sudo bash $0)"
fi

# ---------- 锁处理函数 ----------
# 检查是否有 apt/dpkg 进程占用锁，若有则尝试等待或引导用户
wait_for_apt_lock() {
    local lock_file="/var/lib/dpkg/lock-frontend"
    local max_wait=60
    local waited=0
    while [ -f "$lock_file" ] && [ $waited -lt $max_wait ]; do
        # 查看哪个进程占用锁
        local pid=$(lsof -t "$lock_file" 2>/dev/null | head -n1)
        if [ -n "$pid" ]; then
            local proc_name=$(ps -p $pid -o comm= 2>/dev/null || echo "未知")
            warn "检测到 apt/dpkg 进程 (PID: $pid, 命令: $proc_name) 正在运行，可能占用锁。"
        else
            warn "检测到锁文件存在，但未能识别进程。"
        fi
        info "等待中... (${waited}s/${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done

    if [ -f "$lock_file" ]; then
        echo -e "\n${RED}警告：等待 ${max_wait} 秒后锁仍未释放。${NC}"
        echo "您可以选择："
        echo "  1) 跳过软件包卸载 (仅清理配置和文件)"
        echo "  2) 强制终止占用进程 (可能不安全，谨慎使用)"
        echo "  3) 退出脚本，待手动解决后再运行"
        read -p "请选择 (1/2/3): " choice
        case $choice in
            1)
                warn "将跳过软件包卸载，仅清理配置和文件。"
                return 1  # 告诉调用者跳过卸载
                ;;
            2)
                info "尝试强制终止占用进程..."
                local pids=$(lsof -t "$lock_file" 2>/dev/null)
                if [ -n "$pids" ]; then
                    kill -9 $pids 2>/dev/null || true
                    info "已终止进程，继续执行。"
                    # 删除锁文件（防止残留）
                    rm -f "$lock_file" /var/lib/dpkg/lock 2>/dev/null || true
                    dpkg --configure -a 2>/dev/null || true
                    return 0
                else
                    warn "未能找到占用进程，尝试删除锁文件。"
                    rm -f "$lock_file" /var/lib/dpkg/lock 2>/dev/null || true
                    dpkg --configure -a 2>/dev/null || true
                    return 0
                fi
                ;;
            *)
                error "用户选择退出，请手动处理 apt 锁后再运行。"
                ;;
        esac
    fi
    return 0  # 锁已释放或不存在
}

clear
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}  警告：此脚本将彻底卸载 WireGuard 并清理所有相关配置！${NC}"
echo -e "${RED}  包括：服务、配置文件、密钥、防火墙规则、软件包等。${NC}"
echo -e "${RED}  操作不可逆，请确认您已备份重要数据。${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
read -p "输入 'yes' 继续，其他任意键退出: " confirm
if [ "$confirm" != "yes" ]; then
    info "已取消卸载操作。"
    exit 0
fi

# 备份配置
BACKUP_DIR="/root/wireguard_backup_$(date +%Y%m%d_%H%M%S)"
info "创建配置备份到 $BACKUP_DIR"
mkdir -p $BACKUP_DIR
if [ -d /etc/wireguard ]; then
    cp -r /etc/wireguard $BACKUP_DIR/
    info "已备份 /etc/wireguard"
fi
if [ -d /root/wireguard ]; then
    cp -r /root/wireguard $BACKUP_DIR/client_configs
    info "已备份 /root/wireguard (客户端配置)"
fi

# ------------------------------------------------------------------
# 1. 停止并禁用服务
step_start "停止并禁用 WireGuard 服务"
if systemctl is-active --quiet wg-quick@wg0; then
    systemctl stop wg-quick@wg0
    info "服务已停止"
fi
if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
    systemctl disable wg-quick@wg0
    info "服务已禁用"
fi
step_end "停止并禁用服务"

# ------------------------------------------------------------------
# 2. 删除配置文件
step_start "删除 /etc/wireguard 目录"
if [ -d /etc/wireguard ]; then
    rm -rf /etc/wireguard
    info "已删除 /etc/wireguard"
else
    warn "/etc/wireguard 不存在，跳过"
fi
step_end "删除配置文件"

step_start "删除 /root/wireguard 目录（客户端配置）"
if [ -d /root/wireguard ]; then
    rm -rf /root/wireguard
    info "已删除 /root/wireguard"
else
    warn "/root/wireguard 不存在，跳过"
fi
step_end "删除客户端配置"

# ------------------------------------------------------------------
# 3. 卸载软件包（带锁检测）
step_start "卸载 WireGuard 和 resolvconf"
read -p "是否卸载 wireguard 和 resolvconf 软件包？(y/n): " uninstall_pkg
if [[ "$uninstall_pkg" =~ ^[Yy]$ ]]; then
    # 调用锁等待函数，如果返回 1 则跳过卸载
    if wait_for_apt_lock; then
        apt purge wireguard resolvconf -y
        apt autoremove -y
        info "软件包已卸载"
    else
        warn "由于锁问题，已跳过软件包卸载。"
    fi
else
    warn "保留软件包，仅删除配置"
fi
step_end "卸载软件包"

# ------------------------------------------------------------------
# 4. 恢复 sysctl 设置（删除 ip_forward 配置）
step_start "恢复 sysctl 设置 (移除 net.ipv4.ip_forward=1)"
if grep -q "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.conf; then
    sed -i '/^net.ipv4.ip_forward\s*=\s*1/d' /etc/sysctl.conf
    sysctl -p > /dev/null
    info "已从 /etc/sysctl.conf 删除 ip_forward=1 并生效"
else
    warn "未找到 ip_forward=1 配置，跳过"
fi
step_end "恢复 sysctl 设置"

# ------------------------------------------------------------------
# 5. 清理 UFW 规则
step_start "清理 UFW 防火墙规则"
if command -v ufw &> /dev/null; then
    ufw delete allow 22/tcp > /dev/null 2>&1 || true
    ufw delete allow 51820/udp > /dev/null 2>&1 || true
    sed -i 's/DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/g' /etc/default/ufw
    ufw reload > /dev/null 2>&1
    info "UFW 规则已清理，转发策略恢复为 DROP"
else
    warn "UFW 未安装，跳过"
fi
step_end "清理 UFW 防火墙规则"

# ------------------------------------------------------------------
# 6. 清理 iptables 规则（根据备份中的网卡）
step_start "清理残留的 iptables 规则"
if [ -f $BACKUP_DIR/wireguard/wg0.conf ]; then
    INTERFACE=$(grep -E '^PostUp.*-o' $BACKUP_DIR/wireguard/wg0.conf | sed -n 's/.*-o \([^ ]*\).*/\1/p' | head -n1)
    if [ -n "$INTERFACE" ]; then
        iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
        iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE 2>/dev/null || true
        info "已尝试删除 iptables 规则 (网卡: $INTERFACE)"
    else
        warn "无法从备份中提取网卡，跳过 iptables 清理"
    fi
else
    warn "未找到备份的 wg0.conf，跳过 iptables 清理"
fi
step_end "清理 iptables 规则"

# ------------------------------------------------------------------
# 完成
info "========== 卸载清理完成 =========="
info "所有 WireGuard 相关配置已清除。"
info "备份文件保存在: $BACKUP_DIR"
echo -e "\n${YELLOW}如果需要恢复，请查看备份目录。${NC}"
echo -e "${YELLOW}如果服务器重启后，请确认网络配置是否正常。${NC}"
