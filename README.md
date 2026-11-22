# OpenVPN IPv6 优先安装器

## 一键安装

```bash
wget -qO openvpn-install.sh https://raw.githubusercontent.com/gdy1v1/openvpn-install-ipv6/master/openvpn-install.sh && bash openvpn-install.sh
```

**安装前先确认 VPS 已启用公网 IPv6**，安装时选择 **1) UDP**。安装器会自动配置 **IPv6 优先、IPv4 备用**；支持 IPv4 / IPv6 流量经 VPS 出口访问互联网。

## 安装前检查

```bash
ip -6 -o addr show scope global
curl -6 https://www.cloudflare.com/cdn-cgi/trace
```

必须能看到 VPS 的公网 IPv6，且 `curl -6` 正常返回。部分 RackNerd Ubuntu / Debian 需要先按服务商提供的步骤启用 IPv6。**如果安装前 IPv6 不可用，本脚本不会自动启用 IPv6 优先功能。**

## 安装后验证

Windows PowerShell（**先连接 OpenVPN**）：

```powershell
curl.exe -4 https://www.cloudflare.com/cdn-cgi/trace
curl.exe -6 https://www.cloudflare.com/cdn-cgi/trace
```

检查输出中的 `ip=`：IPv4 应为 VPS 公网 IPv4，IPv6 应为 VPS 公网 IPv6，**不应是本地运营商的 IP**。`loc=` 是网站的地理定位判断，不等于是否泄漏。

服务器查看监听与配置：

```bash
ss -lunp
cat /etc/openvpn/server/client-common.txt
```

客户端模板应先列出 IPv6 的 `remote ... udp6`，再列出 IPv4 的 `remote ... udp4`。

## 新增客户端 / 管理 OpenVPN

在服务器上重新执行：

```bash
bash openvpn-install.sh
```

选择 `1) Add a new client` 新增客户端；无需重装。生成的 `.ovpn` 文件通常位于执行脚本时的目录，导入 OpenVPN 客户端即可。**不要公开上传 .ovpn：其中包含私钥。**

## 记住这些

- **新 VPS / 重装 Ubuntu：**先启用公网 IPv6，再执行上方一键安装命令，选择 UDP。
- **已有 OpenVPN：**再次运行脚本只显示管理菜单，**不会自动修改现有服务端配置**，不要为了升级而卸载正常运行的 VPN。
- **出现 IPv6 泄漏：**先检查客户端是否接受 IPv6 默认路由，再检查服务器的 IPv6 转发和 NAT；仅将 `remote` 改成 IPv6 不够。
- **防火墙：**不建议关闭。保留 `openvpn-iptables` 服务，它还负责 VPN 的 NAT 和转发。
- **断线保护：**如果不希望 VPN 断开后直接暴露本地 IP，请在客户端开启并测试 kill switch。
- 本 Fork 的 IPv6 优先改动适用于**首次安装、存在公网 IPv6、选择 UDP**的情况；尚未在全新 VPS 完整实测。

原版项目：[Nyr/openvpn-install](https://github.com/Nyr/openvpn-install)（MIT License）。
