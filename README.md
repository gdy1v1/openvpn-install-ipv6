# OpenVPN installer — IPv6-first (IPv4 fallback)

A small fork of [Nyr/openvpn-install](https://github.com/Nyr/openvpn-install) for Linux VPS users who want OpenVPN clients to **connect over IPv6 first**, while retaining **IPv4 fallback**.

The original Nyr installer and its license remain the basis of this project.

## Install on a new VPS

Configure a publicly reachable IPv6 address on your VPS **before running the installer**.

```bash
ip -6 -o addr show scope global
```

Then download and inspect the installer:

```bash
curl -fsSLo openvpn-install.sh https://raw.githubusercontent.com/gdy1v1/openvpn-install-ipv6/master/openvpn-install.sh
less openvpn-install.sh
sudo bash openvpn-install.sh
```

Select **UDP** when prompted. Choose your port, DNS and first client name as usual.

**No reinstall is needed on an already working OpenVPN server.** Running Nyr's installer on an existing server opens its client-management menu, and will not rewrite the current server configuration.

## Behavior

When a global IPv6 address is present at installation time **and UDP is selected**:

- The server listens with `proto udp6` on a dual-stack socket (IPv6 and IPv4-mapped IPv6). The installer enables Linux's `net.ipv6.bindv6only=0` persistently.
- Generated clients prefer `remote <server-IPv6> <port> udp6` and then fall back to `remote <server-IPv4> <port> udp4`.
- Client **internet traffic** is routed through the VPN for both IPv4 and IPv6: the original Nyr `server-ipv6`, `redirect-gateway`, IPv4 NAT and IPv6 SNAT logic remain enabled.
- The installer adds an IPv6 UDP INPUT accept rule when using `iptables` (and leaves Nyr's `firewalld` port rule in place). Do not remove the VPN forwarding/NAT rules.

On a VPS **without IPv6**, or when **TCP** is selected, the original IPv4 transport behavior is retained. This fork does not implement TCP-over-IPv6 dual-stack.

```ini
client
dev tun
proto udp
remote 2001:db8::100 1718 udp6
remote 203.0.113.10 1718 udp4
```

The addresses above are **documentation examples**, not addresses to use. The installer automatically generates the real addresses and selected port for your server.

## Verify after connecting

On the client (with the VPN connected):

```bash
curl -4 https://www.cloudflare.com/cdn-cgi/trace
curl -6 https://www.cloudflare.com/cdn-cgi/trace
```

The returned `ip=` fields should correspond to the VPS's external IPv4 and IPv6 addresses, **not the client's ISP IPs**. Test both, because changing the VPN connection transport alone does not guarantee that all client IPv6 traffic routes through the tunnel. A client that ignores pushed routes may require separate configuration or a kill switch.

On the server:

```bash
ss -lunp
grep -E '^(proto|server-ipv6|push "redirect-gateway)' /etc/openvpn/server/server.conf
ip6tables -t nat -S POSTROUTING
```

If the VPS provider uses an external firewall, allow your selected UDP port for **both** address families. If IPv4 fallback does not work, check that the VPS and kernel support IPv4-mapped IPv6 sockets, and that `net.ipv6.bindv6only` is `0`.

## Using the existing client manager

After initial installation, running `sudo bash openvpn-install.sh` again adds/revokes clients using the existing template. New clients get IPv6-first settings automatically.

## Limitations and notes

- This is intended for Linux-based VPS hosts supported by the original Nyr installer.
- The installer needs a working and reachable public IPv6 **before** first installation. If your VPS provider requires enabling IPv6 manually, do that first.
- This does not disable the system firewall. Disabling firewalls normally does not improve OpenVPN throughput and exposes unrelated services.
- Neither IPv6-first transport nor a VPN can guarantee anonymity or prevent sites from identifying an account by other signals.
- Do not run a reinstall just to obtain an updated client profile; preserve your existing keys and certificates.

Upstream: https://github.com/Nyr/openvpn-install
