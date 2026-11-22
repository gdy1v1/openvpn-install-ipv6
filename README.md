# OpenVPN IPv6 优先安装器（IPv4 备用）

基于 [Nyr/openvpn-install](https://github.com/Nyr/openvpn-install) 的个人维护版本，目标是：**新 VPS 安装一次 OpenVPN，自动优先走 IPv6、保留 IPv4 备用，并让 VPN 内的 IPv4 / IPv6 流量都从 VPS 出口访问互联网。**

> **下次重装先看这里：**
>
> 1. **先在 VPS 上开通并确认公网 IPv6 能访问互联网，再运行安装器。**
> 2. 安装时选择 **UDP（选项 1）**。有公网 IPv6 时，安装器才会自动采用 IPv6 优先方案。
> 3. 安装完，在客户端分别执行 `curl -4` 和 `curl -6` 检查公网出口。**只看到客户端连接了 IPv6，不等于解决了 IPv6 泄漏。**
> 4. **不要使用原作者的 `https://git.io/vpn` 地址安装**：它下载的是上游原版，不是本仓库修改版。

## 目录

- [一、新 VPS 最简安装步骤](#一新-vps-最简安装步骤)
- [二、安装器做了什么](#二安装器做了什么)
- [三、安装后如何验证](#三安装后如何验证)
- [四、以后新增客户端](#四以后新增客户端)
- [五、问题排查](#五问题排查)
- [六、重装、迁移、更新注意事项](#六重装迁移更新注意事项)
- [七、安全与隐私](#七安全与隐私)
- [八、项目说明](#八项目说明)

## 一、新 VPS 最简安装步骤

### 1. 准备服务器

建议使用 Ubuntu 22.04 或以上的受支持系统（也支持上游安装器列出的 Debian、AlmaLinux、Rocky Linux、CentOS、Fedora）。需要：

- root / sudo 和 SSH 访问权限。
- 可正常联网的 VPS，且服务器允许使用 TUN。
- **公网 IPv4**（作为备用连接）。
- **已在系统网卡上配置好、能够连通公网的 IPv6**。
- 开放你选择的 OpenVPN UDP 端口（IPv4 和 IPv6）；如 VPS 面板有额外防火墙，面板规则也要放行。

检查公网 IPv4 和 IPv6：

```bash
ip -4 -o addr show scope global
ip -6 -o addr show scope global
ip -6 route
```

测试服务器能不能通过 IPv6 出网：

```bash
ping -6 -c 3 2606:4700:4700::1111
curl -6 https://www.cloudflare.com/cdn-cgi/trace
```

`ip -6` 里应有类似 `2607:.../64` 的公网地址。`fe80::` 是链路本地地址，`fddd:...` 可能是 OpenVPN 内部地址，都**不能**当作 VPS 的公网 IPv6。

**RackNerd 特别注意：** 某些 Ubuntu / Debian 实例需要按 RackNerd 工单说明**手工启用 IPv6**。先保证网卡（通常是 `eth0`）有公网 IPv6，默认 IPv6 路由也正常，再执行安装器。IP、前缀、网关和网卡名以服务商实际分配为准；**不要照抄旧 VPS 地址**。也不要为了启用 IPv6 无条件关闭路由通告（RA），否则可能丢失默认路由。

### 2. 下载本 Fork 的安装器

SSH 登录新服务器，执行：

```bash
cd /root
wget -qO openvpn-install.sh https://raw.githubusercontent.com/gdy1v1/openvpn-install-ipv6/master/openvpn-install.sh
bash -n openvpn-install.sh
bash openvpn-install.sh
```

建议首次使用时先阅读下载的脚本，再以 root 权限运行。使用普通账户时可执行 `sudo bash openvpn-install.sh`。

首次安装依次选择：

| 安装项 | 推荐值 | 说明 |
| --- | --- | --- |
| Protocol | **1：UDP** | 双栈 IPv6 优先功能仅针对 UDP |
| Port | `1194` 或自定义 | 以前 RackNerd 使用过 `1718`，**不是必须用 1718** |
| DNS | `3：1.1.1.1` 或按需选择 | 也可以使用系统 DNS |
| Client name | 自定义，如 `win11` | 首个客户端文件名为 `win11.ovpn` |
| IPv6 地址选择 | 公网地址（如 `2607:...`） | 多个 IPv6 时选你要用的公网地址，不要选 VPN 内部地址 |

**关键判断：** 首次安装时如果没检测到公网 IPv6，或你选择了 TCP，安装器不会采用 IPv6 优先的 UDP 双栈连接配置。需要先修好 IPv6，再首次安装。

### 3. 获取 `.ovpn` 客户端文件

首次安装成功后，终端会输出客户端文件的**完整路径**。如果从 `/root` 执行脚本，文件一般在 `/root/客户端名.ovpn`。

可以用 WinSCP / SFTP 从 VPS 安全地取回文件，再导入 Windows 的 OpenVPN Connect、Android OpenVPN 客户端等。

`.ovpn` 含有私有密钥/证书：**不要提交到公开 GitHub 仓库，不要贴到公开聊天或论坛。**

### 4. 新 VPS 一行安装（熟悉脚本后使用）

```bash
wget -qO openvpn-install.sh https://raw.githubusercontent.com/gdy1v1/openvpn-install-ipv6/master/openvpn-install.sh && bash openvpn-install.sh
```

这条命令只适用于**你已经确认服务器 IPv6 正常、也信任当前仓库代码**的场景。新系统建议先用上面的分步方式检查。

## 二、安装器做了什么

当安装器在首次运行时检测到公网 IPv6，并且你选了 UDP，它会自动：

1. 在服务器端使用 `proto udp6`，不再强制 `local <IPv4>` 绑定；通过 Linux 的 IPv4-mapped IPv6 Socket 兼容 IPv4 UDP。
2. 设置 `net.ipv6.bindv6only=0`，并将配置写入 `/etc/sysctl.d/99-openvpn-ipv6-dualstack.conf` 以便重启后保留。
3. 生成 **IPv6 优先、IPv4 备用**的客户端配置。
4. 保留上游 Nyr 的 OpenVPN 内部 IPv4 网段、IPv6 网段、双栈默认路由推送、IPv4 NAT 和 IPv6 SNAT。
5. 使用 iptables 时，为 IPv6 UDP 入站补充放行规则；不会自动关闭整台服务器的防火墙。

客户端生成结果类似：

```ini
client
dev tun
proto udp
remote 2001:db8::100 1718 udp6
remote 203.0.113.10 1718 udp4
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
```

以上 `2001:db8::100`、`203.0.113.10` 是**文档示例地址**，不是服务器真实 IP；`1718` 也是示例端口，实际值由安装时选择决定。

**理解两个不同的 IPv6：**

| 场景 | 含义 | 检查重点 |
| --- | --- | --- |
| 客户端 → OpenVPN 服务器 | VPN **连接使用 IPv6**，IPv4 备用 | `.ovpn` 的两个 `remote` |
| 客户端 → 网站（经过 VPN） | 网站看到 **VPS 的公网 IPv4 / IPv6** | `curl -4`、`curl -6` 的 `ip=` |

Nyr 的内部 IPv6 网段（默认 `fddd:1194:1194:1194::/64`）是隧道地址，不是网站最终看到的公网地址。此 Fork 默认通过 IPv6 SNAT 使用**所选 VPS 公网 IPv6 地址**出站；不需要为了基本双栈 VPN 特意向 VPS 服务商申请 100 个 IPv6 地址。

IPv6 连接不通时客户端可尝试后面的 IPv4 `remote`；**失败切换并不保证瞬间完成**，具体取决于客户端软件和重试配置。此 Fork 对 **TCP** 或 **IPv4-only** 服务器维持原版的 IPv4 连接行为。

## 三、安装后如何验证

### 1. 服务器确认

```bash
# 服务是否运行
systemctl status openvpn-server@server --no-pager

# 监听端口：把 1718 换成实际端口
ss -lunp | grep 1718

# 服务端 IPv6 和路由配置
grep -E '^(local|port|proto|server-ipv6|push "redirect-gateway)' /etc/openvpn/server/server.conf

# 查看新客户端模板
cat /etc/openvpn/server/client-common.txt

# IPv4/IPv6 NAT（不要清空 NAT 表）
iptables -t nat -S POSTROUTING
ip6tables -t nat -S POSTROUTING

# IPv6 / 双栈相关内核开关
sysctl net.ipv6.bindv6only net.ipv6.conf.all.forwarding
```

期望：`server.conf` 有 `proto udp6`、`server-ipv6` 和包含 `ipv6` 的 `redirect-gateway`；`client-common.txt` 先是 `remote ... udp6`，然后是 `remote ... udp4`；`ss` 能看到 OpenVPN 的 UDP6 监听；双栈 NAT 规则仍存在。

### 2. Windows 11 客户端检查（最重要）

**先连接 VPN**，然后打开 Windows PowerShell：

```powershell
curl.exe -4 https://www.cloudflare.com/cdn-cgi/trace
curl.exe -6 https://www.cloudflare.com/cdn-cgi/trace
```

在结果里分别看 `ip=`：

- `curl.exe -4`：应该是 **VPS 的公网 IPv4**。
- `curl.exe -6`：应该是 **VPS 的公网 IPv6**。
- **绝对不能**仍是本地宽带/手机运营商的公网 IPv4 或 IPv6。

示例（当时的一台 RackNerd VPS，**迁移后会变化**）：

| 测试 | 当时预期出口 |
| --- | --- |
| IPv4 | `192.236.156.244` |
| IPv6 | `2607:9d00:2000:2f2::b029:241a` |

以前出现过 `ip=240e:...`、`loc=CN` 的情况：这说明请求仍由中国运营商的 IPv6 出口发出。**判断是否泄漏应以 `ip=` 对比服务器出口为准，不应只看 `loc=`**；IP 地理定位数据库可能有误差。

### 3. Android 客户端检查

连接 OpenVPN 后，用手机浏览器访问：

- https://www.cloudflare.com/cdn-cgi/trace
- https://test-ipv6.com/

同时测试 IPv4/IPv6；如果需要精确区分，请使用支持 `curl -4` 和 `curl -6` 的终端工具。**Android、Windows 及不同客户端版本的路由处理可能不同**，不要只凭“VPN 已连接”判断没有泄漏。

### 4. VPN 断开时的行为

VPN **连接成功时**双栈走 VPS，不等于 VPN **断开、掉线、切换网络时**仍能阻止直连。如果需要防止断线后的真实 IP 暴露，请另行启用客户端的 kill switch / 阻止无 VPN 连接，并实测该功能。

## 四、以后新增客户端

**不需要重新安装，也不需要重新修改 IPv6 配置。**

在 VPS 上进入你保存脚本的位置并再次运行：

```bash
cd /root
bash openvpn-install.sh
```

会出现 Nyr 原有管理菜单：

```text
1) Add a new client
2) Revoke an existing client
3) Remove OpenVPN
4) Exit
```

选 `1`，输入新的客户端名称。新生成的 `.ovpn` 会使用 `/etc/openvpn/server/client-common.txt` 的模板，默认仍然是 IPv6 优先、IPv4 备用。

查看模板（只查看，不修改证书）：

```bash
cat /etc/openvpn/server/client-common.txt
```

**已有的 `.ovpn` 不会因为 GitHub 更新而自动改变**。如果是已经运行的 Nyr 原版服务器，下载本 Fork 并再次运行也只会进入管理菜单，**不会自动迁移已有服务端配置**。不要为了更新模板而卸载正在正常使用的 VPN。

## 五、问题排查

### 情况 A：安装完还是只有 IPv4

检查：

```bash
ip -6 -o addr show scope global
grep -E '^(local|proto|server-ipv6)' /etc/openvpn/server/server.conf
cat /etc/openvpn/server/client-common.txt
```

通常是**首次安装前 IPv6 没配置好**，或安装时选择了 TCP。`proto udp6` 只会在检测到 IPv6 且选择 UDP 时启用。

### 情况 B：OpenVPN 连接成功，但 `curl -6` 显示本地运营商地址

这就是 **IPv6 出口绕过 VPN**，不是简单更换 `remote` 能解决的。检查：

```bash
grep -E '^(server-ipv6|push "redirect-gateway)' /etc/openvpn/server/server.conf
ip6tables -t nat -vnL POSTROUTING
sysctl net.ipv6.conf.all.forwarding
```

同时检查客户端是否接受 VPN 推送的 IPv6 默认路由、有没有配置分流（split tunneling）、客户端是否支持 IPv6 隧道。修好后再测试 `curl -4` 和 `curl -6`。

### 情况 C：IPv6 地址能 ping 通，但 VPN 连接不上

检查云厂商防火墙、系统防火墙是否允许**实际 OpenVPN 端口的 UDP IPv6 入站**：

```bash
grep '^port ' /etc/openvpn/server/server.conf
ss -lunp
ip6tables -S INPUT
sysctl net.ipv6.bindv6only
journalctl -u openvpn-server@server -n 80 --no-pager
```

如果使用了 `1194` 而不是 `1718`，请按实际端口排查。确认 VPS 的 IPv6 是公网可达，不仅仅是网卡上显示了地址。

### 情况 D：VPN 能连接，但网站打不开

查看转发和 NAT；**不要关掉 `openvpn-iptables` 服务**，它还负责 VPN 的 NAT / FORWARD：

```bash
systemctl status openvpn-iptables --no-pager
iptables -t nat -S POSTROUTING
ip6tables -t nat -S POSTROUTING
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
ip -6 route
```

若 IPv4 正常、IPv6 不正常，重点检查 IPv6 出口、默认路由、IPv6 SNAT 和客户端 IPv6 路由。

### 情况 E：要回退某次服务端修改

本仓库的脚本**不会自动备份现有 OpenVPN 证书和配置**。在手工改动之前，先备份：

```bash
cp -a /etc/openvpn/server/server.conf /etc/openvpn/server/server.conf.bak
cp -a /etc/openvpn/server/client-common.txt /etc/openvpn/server/client-common.txt.bak
```

如需恢复服务端配置：

```bash
cp -a /etc/openvpn/server/server.conf.bak /etc/openvpn/server/server.conf
systemctl restart openvpn-server@server
```

不要把这些路径里的密钥或完整配置目录提交到公开 GitHub。

## 六、重装、迁移、更新注意事项

| 操作 | 是否需要重新安装 / 修改 |
| --- | --- |
| 重启 VPS / OpenVPN | **不需要**，相关服务和配置会保留 |
| 新增 / 撤销客户端 | 重新运行安装器，进管理菜单 |
| 换一台 VPS，首次安装 OpenVPN | **先启用公网 IPv6，再运行本 Fork** |
| 重装 Ubuntu | 所有原有文件可能丢失，先备份，再重新安装 |
| 下载新版安装脚本到现有 VPS | 只更新脚本文件，不会自动修改正在运行的服务配置 |
| 执行菜单中的 `Remove OpenVPN` | 会移除 OpenVPN，**不要误选** |

迁移前建议妥善备份当前客户端 `.ovpn`、证书及 `/etc/openvpn/server/` 的配置和 PKI 文件；其中含**私钥**，备份需要加密保护。新装服务器公网地址通常变化，旧 `.ovpn` 不一定还能直接使用。

如果上游 Nyr 发布更新，不要盲目把本仓库覆盖为上游最新版，否则可能丢掉 IPv6 优先修改。更新后至少核对：

- 服务器 `proto udp6` / IPv4 fallback 逻辑。
- 客户端 `remote IPv6 ... udp6` 和 `remote IPv4 ... udp4`。
- IPv6 入站规则、IPv4 / IPv6 NAT。
- 双栈内核参数与卸载清理逻辑。

## 七、安全与隐私

- **不建议关闭整台服务器的防火墙**，通常不会显著提高 VPN 速度，却会暴露 SSH、Web 等监听端口。
- 必须保留 VPN 所需 NAT 和 FORWARD 规则；不要执行会清空 NAT 表的命令。
- 不要因为“只有自己使用”就认为公网 IP 无法被扫描发现。建议保护好 SSH、及时更新系统。
- VPN 可以让网站看到 VPS 的**网络出口 IP**，但不保证匿名。登录账户、Cookie、浏览器指纹及设备信息仍可能用于识别。
- 如果某个网络本身不支持 IPv6，客户端可尝试 IPv4 备用；如果需要**绝对不直连**，还要用客户端 kill switch，并测试断线场景。

## 八、项目说明

- **本仓库：** https://github.com/gdy1v1/openvpn-install-ipv6
- **上游项目：** https://github.com/Nyr/openvpn-install
- **安装器文件：** `openvpn-install.sh`
- **服务器配置：** `/etc/openvpn/server/server.conf`
- **客户端公共模板：** `/etc/openvpn/server/client-common.txt`
- **网络规则服务：** `openvpn-iptables`（iptables 路径）
- **OpenVPN 服务：** `openvpn-server@server`
- **双栈 sysctl：** `/etc/sysctl.d/99-openvpn-ipv6-dualstack.conf`
- **内网地址：** IPv4 `10.8.0.0/24`；IPv6 `fddd:1194:1194:1194::/64`（上游默认）
- **版权及许可：** 基于 Nyr 原项目，遵循其 MIT License。

> **状态说明（2026-11）：** Fork 已修改并提交安装器逻辑，静态检查过关键修改点，但**尚未在全新 VPS 上跑完一次完整的端到端安装验收**。第一次在新机器上使用时，请按本 README 测试 IPv4 / IPv6 连接和出口；不要直接在唯一一台生产 VPS 上做破坏性重装。
