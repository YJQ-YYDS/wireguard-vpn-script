# wireguard-vpn-script
一键部署 WireGuard VPN 服务器的脚本集 (支持 Ubuntu/Debian)



# WireGuard Ubuntu 一键管理脚本

本仓库包含三套适用于 **Ubuntu 24.04** 的 WireGuard 自动化管理脚本，旨在简化服务端部署、客户端添加和完整卸载流程。所有脚本均采用交互式设计，具备智能检测和容错机制，即使是初学者也能轻松完成 WireGuard 配置。

## 📦 脚本清单

| 脚本文件 | 功能描述 |
|----------|----------|
| `wg_server_setup.sh` | **服务端一键部署**：安装 WireGuard、开启 IP 转发、生成服务器密钥、配置防火墙与 NAT、启动服务并设置开机自启。支持重复运行，自动跳过已完成步骤。 |
| `wg_client_add.sh` | **客户端配置生成**：交互式输入客户端名称和 IP，自动生成密钥对，将客户端信息添加到服务端，并输出可导入客户端的配置文件。支持自动检测子网一致性和 IP 冲突。 |
| `wg_uninstall.sh` | **完整卸载清理**：停止服务、删除所有配置和密钥、移除防火墙规则、恢复系统设置，并可选择性卸载软件包。执行前自动备份所有配置。 |

---

## ✨ 主要特性

- 🧩 **傻瓜式交互**：每一步均有清晰提示，支持输入回退确认，默认值可直接回车使用。
- 🔍 **智能检测**：服务端脚本自动跳过已完成任务；客户端脚本自动推荐未占用的 IP，并校验子网一致性。
- 🛡️ **安全加固**：目录权限自动设为 `077`，操作前自动备份配置文件，卸载时整体备份。
- 🎨 **彩色输出**：信息、警告、错误使用不同颜色标识，执行流程一目了然。
- ☁️ **云主机适配**：醒目提示需在安全组放行 UDP 51820 端口，避免连接失败。

---

## 📋 系统要求

- **操作系统**：Ubuntu 24.04（其他 Debian 系未严格测试）
- **权限**：必须使用 `sudo` 以 root 身份执行
- **网络**：服务器需具备公网 IP（或可映射端口）
- **依赖**：脚本会自动安装 `wireguard` 和 `resolvconf`，如已安装则跳过

---

## 🚀 快速开始

### 方法一：直接下载脚本并执行（推荐）

您可以在服务器上通过以下命令一键下载所有脚本并赋予执行权限：

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/YJQ-YYDS/wireguard-vpn-script/main/wg_server_setup.sh
curl -O https://raw.githubusercontent.com/YJQ-YYDS/wireguard-vpn-script/main/main/wg_client_add.sh
curl -O https://raw.githubusercontent.com/YJQ-YYDS/wireguard-vpn-script/main/main/wg_uninstall.sh

# 赋予执行权限
chmod +x *.sh

方法二：克隆整个仓库
git clone https://github.com/YJQ-YYDS/wireguard-vpn-script.git
cd YOUR_REPO
chmod +x *.sh
