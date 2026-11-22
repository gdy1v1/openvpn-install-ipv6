#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from a one-liner which includes a newline
read -N 999999 -t 0.001

# Detect OS
# $os_version variables aren't always in use, but are kept here for convenience
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
	group_name="nogroup"
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
	group_name="nogroup"
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
	group_name="nobody"
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
	group_name="nobody"
else
	echo "This installer seems to be running on an unsupported distribution.
Supported distros are Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora."
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
	echo "Ubuntu 22.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
	exit
fi

if [[ "$os" == "debian" ]]; then
	if grep -q '/sid' /etc/debian_version; then
		echo "Debian Testing and Debian Unstable are unsupported by this installer."
		exit
	fi
	if [[ "$os_version" -lt 11 ]]; then
		echo "Debian 11 or higher is required to use this installer.
This version of Debian is too old and unsupported."
		exit
	fi
fi

if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
	os_name=$(sed 's/ release.*//' /etc/almalinux-release /etc/rocky-release /etc/centos-release 2>/dev/null | head -1)
	echo "$os_name 9 or higher is required to use this installer.
This version of $os_name is too old and unsupported."
	exit
fi

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi

if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
	echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
	exit
fi

# Store the absolute path of the directory where the script is located
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"


# Per-client IPv6 egress mapping. This is separate from the IPv4/IPv6 address
# used by clients to CONNECT to the VPN server.
IPV6_MAP_FILE="/etc/openvpn/server/ipv6-client-map.tsv"
IPV6_NAT_HELPER="/usr/local/sbin/openvpn-client-ipv6-nat"
IPV6_NAT_SERVICE="openvpn-client-ipv6-nat.service"

vpn_ipv6_network() {
	local network
	network=$(awk '$1 == "server-ipv6" { print $2; exit }' /etc/openvpn/server/server.conf)
	# This installer configures an IPv6 /64 using a compressed :: suffix.
	if [[ "$network" != *"::/64" ]]; then
		echo "Per-client IPv6 egress requires server-ipv6 PREFIX::/64 in server.conf." >&2
		return 1
	fi
	VPN_IPV6_NETWORK="$network"
	VPN_IPV6_PREFIX="${network%::/64}"
}

# Collect only globally scoped IPv6 addresses on the default IPv6 uplink.
get_public_ipv6_addresses() {
	local dev address
	PUBLIC_IPV6_ADDRESSES=()
	dev=$(ip -6 route show default | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
	[[ -n "$dev" ]] || return 0
	while IFS= read -r address; do
		[[ "$address" =~ ^[23][0-9a-fA-F:]+$ ]] && PUBLIC_IPV6_ADDRESSES+=("$address")
	done < <(ip -6 -o addr show dev "$dev" scope global | awk '{split($4,a,"/"); print a[1]}')
}

# SELECTED_IPV6 is empty for shared/default egress, otherwise the chosen IP.
select_client_ipv6_exit() {
	local client_name="$1" n choice current="" default_choice=0
	SELECTED_IPV6=""
	if ! grep -qE '^server-ipv6[[:space:]]' /etc/openvpn/server/server.conf; then
		echo "IPv6 is not enabled for this OpenVPN server; using IPv4 only."
		return 0
	fi
	get_public_ipv6_addresses
	if (( ${#PUBLIC_IPV6_ADDRESSES[@]} == 0 )); then
		echo "No public IPv6 addresses were detected; default egress will be used."
		return 0
	fi
	if [[ -f "$IPV6_MAP_FILE" ]]; then
		current=$(awk -F '\t' -v name="$client_name" '$1==name {print $3; exit}' "$IPV6_MAP_FILE")
	fi
	echo
	echo "Select the IPv6 EXIT address for client $client_name:"
	echo "   0) Shared/default IPv6 exit (no dedicated mapping)"
	for (( n=0; n<${#PUBLIC_IPV6_ADDRESSES[@]}; n++ )); do
		local count
		count=0
		if [[ -f "$IPV6_MAP_FILE" ]]; then
			count=$(awk -F '\t' -v ipv6="${PUBLIC_IPV6_ADDRESSES[n]}" '$3==ipv6 {n++} END {print n+0}' "$IPV6_MAP_FILE")
		fi
		printf '   %d) %s' "$((n+1))" "${PUBLIC_IPV6_ADDRESSES[n]}"
		(( count > 0 )) && printf ' (%d client(s) assigned)' "$count"
		[[ "$current" == "${PUBLIC_IPV6_ADDRESSES[n]}" ]] && printf ' [current]'
		printf '\n'
		[[ "$current" == "${PUBLIC_IPV6_ADDRESSES[n]}" ]] && default_choice=$((n+1))
	done
	while :; do
		read -r -p "IPv6 exit [$default_choice]: " choice
		[[ -z "$choice" ]] && choice="$default_choice"
		if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice <= ${#PUBLIC_IPV6_ADDRESSES[@]} )); then
			break
		fi
		echo "Invalid IPv6 choice."
	done
	if (( 10#$choice > 0 )); then
		SELECTED_IPV6="${PUBLIC_IPV6_ADDRESSES[10#$choice-1]}"
	fi
}

# Use CCD to pin the VPN-internal IPv6 so source-based SNAT stays deterministic.
ensure_ipv6_client_ccd() {
	local configured
	CCD_RESTART_REQUIRED=0
	configured=$(awk '$1=="client-config-dir" {print $2; exit}' /etc/openvpn/server/server.conf)
	if [[ -n "$configured" ]]; then
		CCD_DIRECTORY="${configured%\"}"
		CCD_DIRECTORY="${CCD_DIRECTORY#\"}"
		if [[ "$CCD_DIRECTORY" != /* ]]; then
			echo "Existing client-config-dir must be an absolute path: $CCD_DIRECTORY" >&2
			return 1
		fi
	else
		CCD_DIRECTORY="/etc/openvpn/server/ccd"
		# Back up server.conf before changing its options.
		cp -an /etc/openvpn/server/server.conf /etc/openvpn/server/server.conf.pre-ipv6-clients.bak
		printf '\nclient-config-dir %s\n' "$CCD_DIRECTORY" >> /etc/openvpn/server/server.conf
		CCD_RESTART_REQUIRED=1
	fi
	mkdir -p "$CCD_DIRECTORY"
	chmod 755 "$CCD_DIRECTORY"
}

install_ipv6_nat_helper() {
	# The dedicated chain is consulted before the installer's general SNAT rule.
	# Rules are reloaded on boot and whenever a client's exit changes.
	cat > "$IPV6_NAT_HELPER" <<'NAT_HELPER_SCRIPT'
#!/bin/bash
set -euo pipefail
MAP="/etc/openvpn/server/ipv6-client-map.tsv"
CHAIN="OVPN6_CLIENT_SNAT"
IP6TABLES=$(command -v ip6tables)
NET=$(awk '$1 == "server-ipv6" {print $2; exit}' /etc/openvpn/server/server.conf)
[[ -n "$NET" ]] || exit 1
case "${1:-apply}" in
	apply)
		"$IP6TABLES" -w 5 -t nat -N "$CHAIN" 2>/dev/null || true
		"$IP6TABLES" -w 5 -t nat -F "$CHAIN"
		if [[ -f "$MAP" ]]; then
			while IFS=$'\t' read -r client tunnel_ip public_ip; do
				[[ -n "$client" && -n "$tunnel_ip" && -n "$public_ip" ]] || continue
				"$IP6TABLES" -w 5 -t nat -A "$CHAIN" -s "${tunnel_ip}/128" -j SNAT --to-source "$public_ip"
			done < "$MAP"
		fi
		"$IP6TABLES" -w 5 -t nat -C POSTROUTING -s "$NET" ! -d "$NET" -j "$CHAIN" 2>/dev/null || \
			"$IP6TABLES" -w 5 -t nat -I POSTROUTING 1 -s "$NET" ! -d "$NET" -j "$CHAIN"
		;;
	remove)
		"$IP6TABLES" -w 5 -t nat -D POSTROUTING -s "$NET" ! -d "$NET" -j "$CHAIN" 2>/dev/null || true
		"$IP6TABLES" -w 5 -t nat -F "$CHAIN" 2>/dev/null || true
		"$IP6TABLES" -w 5 -t nat -X "$CHAIN" 2>/dev/null || true
		;;
	*) echo "Usage: $0 apply|remove" >&2; exit 2 ;;
esac
NAT_HELPER_SCRIPT
	chmod 700 "$IPV6_NAT_HELPER"
	cat > "/etc/systemd/system/$IPV6_NAT_SERVICE" <<EOF
[Unit]
Description=OpenVPN per-client IPv6 SNAT
Wants=network-online.target
After=network-online.target openvpn-iptables.service firewalld.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$IPV6_NAT_HELPER apply
ExecReload=$IPV6_NAT_HELPER apply
ExecStop=$IPV6_NAT_HELPER remove
[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now "$IPV6_NAT_SERVICE" || return 1
	systemctl reload "$IPV6_NAT_SERVICE"
}

# A high-address portion of the existing ULA /64 is reserved for managed CCD
# clients. Regular OpenVPN pool allocations start at the beginning of the /64.
allocate_client_tunnel_ipv6() {
	local slot candidate
	vpn_ipv6_network || return 1
	for (( slot=1; slot<=4095; slot++ )); do
		printf -v candidate '%s::ffff:%x' "$VPN_IPV6_PREFIX" "$slot"
		if [[ ! -f "$IPV6_MAP_FILE" ]] || ! grep -Fq "${candidate}"$'\t' "$IPV6_MAP_FILE"; then
			CLIENT_TUNNEL_IPV6="$candidate"
			return 0
		fi
	done
	echo "No free managed VPN IPv6 slots remain." >&2
	return 1
}

remove_client_ipv6_mapping() {
	local name="$1" old_tunnel="" ccd_file="" tmp
	[[ -f "$IPV6_MAP_FILE" ]] || return 0
	old_tunnel=$(awk -F '\t' -v name="$name" '$1==name {print $2; exit}' "$IPV6_MAP_FILE")
	[[ -n "$old_tunnel" ]] || return 0
	# Only delete the ifconfig-ipv6-push line installed for this client.
	CCD_DIRECTORY=$(awk '$1=="client-config-dir" {print $2; exit}' /etc/openvpn/server/server.conf)
	CCD_DIRECTORY="${CCD_DIRECTORY%\"}"
	CCD_DIRECTORY="${CCD_DIRECTORY#\"}"
	if [[ "$CCD_DIRECTORY" == /* && -f "$CCD_DIRECTORY/$name" ]]; then
		ccd_file="$CCD_DIRECTORY/$name"
		sed -i -E '/^[[:space:]]*ifconfig-ipv6-push[[:space:]]/d' "$ccd_file"
		[[ ! -s "$ccd_file" ]] && rm -f "$ccd_file"
	fi
	tmp=$(mktemp "${IPV6_MAP_FILE}.XXXXXX") || return 1
	awk -F '\t' -v name="$name" '$1!=name' "$IPV6_MAP_FILE" > "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$IPV6_MAP_FILE"
	if systemctl is-active --quiet "$IPV6_NAT_SERVICE"; then
		systemctl reload "$IPV6_NAT_SERVICE" || return 1
	fi
}

set_client_ipv6_exit() {
	local name="$1" public_ip="$2" old_tunnel="" tmp ccd_file
	if [[ -z "$public_ip" ]]; then
		remove_client_ipv6_mapping "$name" || return 1
		echo "Client $name now uses the shared/default IPv6 exit. Reconnect to apply."
		return 0
	fi
	vpn_ipv6_network || return 1
	# Verify that the chosen address is currently assigned to our uplink.
	get_public_ipv6_addresses
	local found=0 item
	for item in "${PUBLIC_IPV6_ADDRESSES[@]}"; do
		[[ "$item" == "$public_ip" ]] && found=1
	done
	if (( found == 0 )); then
		echo "IPv6 $public_ip is not assigned to this VPS." >&2
		return 1
	fi
	if [[ -f "$IPV6_MAP_FILE" ]]; then
		old_tunnel=$(awk -F '\t' -v name="$name" '$1==name {print $2; exit}' "$IPV6_MAP_FILE")
	fi
	if [[ -n "$old_tunnel" ]]; then
		CLIENT_TUNNEL_IPV6="$old_tunnel"
	else
		allocate_client_tunnel_ipv6 || return 1
	fi
	ensure_ipv6_client_ccd || return 1
	ccd_file="$CCD_DIRECTORY/$name"
	if [[ -z "$old_tunnel" && -f "$ccd_file" ]] && grep -qE '^[[:space:]]*ifconfig-ipv6-push[[:space:]]' "$ccd_file"; then
		echo "Existing unmanaged IPv6 push in $ccd_file; refusing to overwrite." >&2
		return 1
	fi
	if [[ -f "$ccd_file" ]]; then
		sed -i -E '/^[[:space:]]*ifconfig-ipv6-push[[:space:]]/d' "$ccd_file"
	fi
	printf 'ifconfig-ipv6-push %s/64 %s::1\n' "$CLIENT_TUNNEL_IPV6" "$VPN_IPV6_PREFIX" >> "$ccd_file"
	chmod 644 "$ccd_file"
	mkdir -p "$(dirname "$IPV6_MAP_FILE")"
	tmp=$(mktemp "${IPV6_MAP_FILE}.XXXXXX") || return 1
	if [[ -f "$IPV6_MAP_FILE" ]]; then
		awk -F '\t' -v name="$name" '$1!=name' "$IPV6_MAP_FILE" > "$tmp"
	fi
	printf '%s\t%s\t%s\n' "$name" "$CLIENT_TUNNEL_IPV6" "$public_ip" >> "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$IPV6_MAP_FILE"
	install_ipv6_nat_helper || return 1
	if (( CCD_RESTART_REQUIRED )); then
		echo "Enabling per-client OpenVPN configuration (brief VPN reconnect required)."
		systemctl restart openvpn-server@server.service || return 1
	fi
	echo "IPv6 exit for $name: $public_ip"
	echo "Reconnect this OpenVPN client to apply the new IPv6 assignment."
}

list_client_ipv6_exits() {
	echo
	echo "Dedicated IPv6 exits (other clients use the shared/default IPv6 exit):"
	if [[ ! -s "$IPV6_MAP_FILE" ]]; then
		echo "   None."
		return
	fi
	awk -F '\t' '{printf "   %-20s %-42s (VPN: %s)\n",$1,$3,$2}' "$IPV6_MAP_FILE"
}

list_valid_clients() {
	# EasyRSA CN is normalized by this installer when certificates are created.
	awk -F '\t' '$1 == "V" {sub(/^.*CN=/,"",$NF); print $NF}' /etc/openvpn/server/easy-rsa/pki/index.txt
}

select_existing_client() {
	local prompt="$1" choice n
	mapfile -t VALID_CLIENTS < <(list_valid_clients)
	if (( ${#VALID_CLIENTS[@]} == 0 )); then
		echo "There are no valid clients."
		return 1
	fi
	echo "$prompt"
	for (( n=0; n<${#VALID_CLIENTS[@]}; n++ )); do
		printf '   %d) %s\n' "$((n+1))" "${VALID_CLIENTS[n]}"
	done
	while :; do
		read -r -p "Client: " choice
		if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( 10#$choice <= ${#VALID_CLIENTS[@]} )); then
			SELECTED_CLIENT="${VALID_CLIENTS[10#$choice-1]}"
			return 0
		fi
		echo "Invalid client selection."
	done
}

if [[ ! -e /etc/openvpn/server/server.conf ]]; then
	# Detect some Debian minimal setups where neither wget nor curl are installed
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required to use this installer."
		read -n1 -r -p "Press any key to install Wget and continue..."
		apt-get update
		apt-get install -y wget
	fi
	clear
	echo 'Welcome to this OpenVPN road warrior installer!'
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo
		echo "Which IPv4 address should be used?"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
	fi
	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	# If system has a single IPv6, it is selected automatically
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	fi
	# If system has multiple IPv6, ask the user to select one
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		number_of_ip6=$(ip -6 addr | grep -c 'inet6 [23]')
		echo
		echo "Which IPv6 address should be used?"
		ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
		read -p "IPv6 address [1]: " ip6_number
		until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$number_of_ip6" ]]; do
			echo "$ip6_number: invalid selection."
			read -p "IPv6 address [1]: " ip6_number
		done
		[[ -z "$ip6_number" ]] && ip6_number="1"
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ip6_number"p)
	fi
	echo
	echo "Which protocol should OpenVPN use?"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [1]: " protocol
	done
	case "$protocol" in
		1|"") 
		protocol=udp
		;;
		2) 
		protocol=tcp
		;;
	esac
	echo
	echo "What port should OpenVPN listen on?"
	read -p "Port [1194]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [1194]: " port
	done
	[[ -z "$port" ]] && port="1194"
	echo
	echo "Select a DNS server for the clients:"
	echo "   1) Default system resolvers"
	echo "   2) Google"
	echo "   3) 1.1.1.1"
	echo "   4) OpenDNS"
	echo "   5) Quad9"
	echo "   6) Gcore"
	echo "   7) AdGuard"
	echo "   8) Specify custom resolvers"
	read -p "DNS server [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-8]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS server [1]: " dns
	done
	# If the user selected custom resolvers, we deal with that here
	if [[ "$dns" = "8" ]]; then
		echo
		until [[ -n "$custom_dns" ]]; do
			echo "Enter DNS servers (one or more IPv4 addresses, separated by commas or spaces):"
			read -p "DNS servers: " dns_input
			# Convert comma delimited to space delimited
			dns_input=$(echo "$dns_input" | tr ',' ' ')
			# Validate and build custom DNS IP list
			for dns_ip in $dns_input; do
				if [[ "$dns_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
					if [[ -z "$custom_dns" ]]; then
						custom_dns="$dns_ip"
					else
						custom_dns="$custom_dns $dns_ip"
					fi
				fi
			done
			if [ -z "$custom_dns" ]; then
				echo "Invalid input."
			fi
		done
	fi
	echo
	echo "Enter a name for the first client:"
	read -p "Name [client]: " unsanitized_client
	# Allow a limited set of characters to avoid conflicts
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	echo
	echo "OpenVPN installation is ready to begin."
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	read -n1 -r -p "Press any key to continue..."
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		mkdir /etc/systemd/system/openvpn-server@server.service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y --no-install-recommends openvpn openssl ca-certificates $firewall
	elif [[ "$os" = "centos" ]]; then
		dnf install -y epel-release
		dnf install -y openvpn openssl ca-certificates tar $firewall
	else
		# Else, OS must be Fedora
		dnf install -y openvpn openssl ca-certificates tar $firewall
	fi
	# If firewalld was just installed, enable it
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.7/EasyRSA-3.2.7.tgz'
	mkdir -p /etc/openvpn/server/easy-rsa/
	{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
	chown -R root:root /etc/openvpn/server/easy-rsa/
	cd /etc/openvpn/server/easy-rsa/
	# Create the PKI, set up the CA and create TLS key
	./easyrsa --batch init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-tls-crypt-key
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
	# Make easy-rsa aware of our external DH file (prevents a warning)
	ln -s /etc/openvpn/server/dh.pem pki/dh.pem
	# Create certificates and CRL
	./easyrsa --batch --days=3650 build-server-full server nopass
	./easyrsa --batch --days=3650 build-client-full "$client" nopass
	./easyrsa --batch --days=3650 gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	cp pki/private/easyrsa-tls.key /etc/openvpn/server/tc.key
	# CRL is read with each client connection, while OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
	chmod o+x /etc/openvpn/server/
	# Prefer IPv6 for the VPN transport while keeping IPv4 connectivity.
	# On Linux, an IPv6 UDP socket can also accept IPv4-mapped packets.
	listen_protocol="$protocol"
	local_bind="local $ip"
	if [[ "$protocol" == "udp" && -n "$ip6" ]]; then
		listen_protocol="udp6"
		local_bind=""
	fi
	# Generate server.conf
	echo "$local_bind
port $port
proto $listen_protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server.conf
	# IPv6
	if [[ -z "$ip6" ]]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	else
		echo 'server-ipv6 fddd:1194:1194:1194::/64' >> /etc/openvpn/server/server.conf
		echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	fi
	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server.conf
	# DNS
	case "$dns" in
		1|"")
			# Locate the proper resolv.conf
			# Needed for systems running systemd-resolved
			if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
				resolv_conf="/etc/resolv.conf"
			else
				resolv_conf="/run/systemd/resolve/resolv.conf"
			fi
			# Obtain the resolvers from resolv.conf and use them for OpenVPN
			grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
			done
		;;
		2)
			echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
		;;
		3)
			echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
		;;
		4)
			echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server.conf
		;;
		5)
			echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 149.112.112.112"' >> /etc/openvpn/server/server.conf
		;;
		6)
			echo 'push "dhcp-option DNS 95.85.95.85"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 2.56.220.2"' >> /etc/openvpn/server/server.conf
		;;
		7)
			echo 'push "dhcp-option DNS 94.140.14.14"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 94.140.15.15"' >> /etc/openvpn/server/server.conf
		;;
		8)
		for dns_ip in $custom_dns; do
			echo "push \"dhcp-option DNS $dns_ip\"" >> /etc/openvpn/server/server.conf
		done
		;;
	esac
	echo 'push "block-outside-dns"' >> /etc/openvpn/server/server.conf
	echo "keepalive 10 120
user nobody
group $group_name
persist-key
persist-tun
verb 3
crl-verify crl.pem" >> /etc/openvpn/server/server.conf
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	fi
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if [[ -n "$ip6" ]]; then
		# Enable net.ipv6.conf.all.forwarding for the system
		echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-openvpn-forward.conf
		# Enable without waiting for a reboot or service restart
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
	# IPv4-mapped IPv6 sockets are required for single-port UDP dual-stack.
	if [[ "$listen_protocol" == "udp6" ]]; then
		echo 'net.ipv6.bindv6only=0' > /etc/sysctl.d/99-openvpn-ipv6-dualstack.conf
		sysctl -w net.ipv6.bindv6only=0
	fi
	if systemctl is-active --quiet firewalld.service; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		# Set NAT for the VPN subnet
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		if [[ -n "$ip6" ]]; then
			firewall-cmd --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --permanent --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
			firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
		fi
	else
		# Create a service to set up persistent iptables rules
		iptables_path=$(command -v iptables)
		ip6tables_path=$(command -v ip6tables)
		# nf_tables is not available as standard in OVZ kernels. So use iptables-legacy
		# if we are in OVZ, with a nf_tables backend and iptables-legacy is available.
		if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
			iptables_path=$(command -v iptables-legacy)
			ip6tables_path=$(command -v ip6tables-legacy)
		fi
		echo "[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -w 5 -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -w 5 -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-iptables.service
		if [[ -n "$ip6" ]]; then
			echo "ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStart=$ip6tables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			# Allow OpenVPN's IPv6 transport socket through the IPv6 filter.
			if [[ "$listen_protocol" == "udp6" ]]; then
				echo "ExecStart=$ip6tables_path -w 5 -I INPUT -p udp --dport $port -j ACCEPT
ExecStop=$ip6tables_path -w 5 -D INPUT -p udp --dport $port -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			fi
		fi
		echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/openvpn-iptables.service
		systemctl enable --now openvpn-iptables.service
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
		# Install semanage if not already present
		if ! hash semanage 2>/dev/null; then
				dnf install -y policycoreutils-python-utils
		fi
		semanage port -a -t openvpn_port_t -p "$protocol" "$port"
	fi
	# If the server is behind NAT, use the correct IP address
	[[ -n "$public_ip" ]] && ip="$public_ip"
	# client-common.txt is created so we have a template to add further users later.
	# Try IPv6 transport first, with IPv4 as a fallback on UDP dual-stack servers.
	if [[ "$listen_protocol" == "udp6" ]]; then
		remote_lines="remote $ip6 $port udp6
remote $ip $port udp4"
	else
		remote_lines="remote $ip $port"
	fi
	echo "client
dev tun
proto $protocol
$remote_lines
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" > /etc/openvpn/server/client-common.txt
	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server.service
	# Build the $client.ovpn file, stripping comments from easy-rsa in the process
	grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
	echo
	echo "Finished!"
	echo
	echo "The client configuration is available in:" "$script_dir"/"$client.ovpn"
	echo "New clients can be added by running this script again."
	if grep -qE '^server-ipv6[[:space:]]' /etc/openvpn/server/server.conf; then
		select_client_ipv6_exit "$client"
		if [[ -n "$SELECTED_IPV6" ]]; then
			set_client_ipv6_exit "$client" "$SELECTED_IPV6" || echo "WARNING: Unable to configure the dedicated IPv6 exit."
		fi
	fi
else
	clear
	echo "OpenVPN is already installed."
	echo
	echo "Select an option:"
	echo "   1) Add a new client"
	echo "   2) Revoke an existing client"
	echo "   3) Remove OpenVPN"
	echo "   4) Change an existing client's IPv6 exit"
	echo "   5) Show dedicated IPv6 exits"
	echo "   6) Exit"
	read -p "Option: " option
	until [[ "$option" =~ ^[1-6]$ ]]; do
		echo "$option: invalid selection."
		read -p "Option: " option
	done
	case "$option" in
		1)
			echo
			echo "Provide a name for the client:"
			read -p "Name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
				echo "$client: invalid name."
				read -p "Name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			select_client_ipv6_exit "$client"
			cd /etc/openvpn/server/easy-rsa/
			./easyrsa --batch --days=3650 build-client-full "$client" nopass
			# Build the $client.ovpn file, stripping comments from easy-rsa in the process
			grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
			echo
			echo "$client added. Configuration available in:" "$script_dir"/"$client.ovpn"
			if [[ -n "$SELECTED_IPV6" ]]; then
				set_client_ipv6_exit "$client" "$SELECTED_IPV6" || echo "WARNING: Dedicated IPv6 exit setup failed; client certificate remains valid."
			fi
			exit
		;;
		2)
			# This option could be documented a bit better and maybe even be simplified
			# ...but what can I say, I want some sleep too
			number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$number_of_clients" = 0 ]]; then
				echo
				echo "There are no existing clients!"
				exit
			fi
			echo
			echo "Select the client to revoke:"
			tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Client: " client_number
			done
			client=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
			echo
			read -p "Confirm $client revocation? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				echo "$revoke: invalid selection."
				read -p "Confirm $client revocation? [y/N]: " revoke
			done
			if [[ "$revoke" =~ ^[yY]$ ]]; then
				cd /etc/openvpn/server/easy-rsa/
				./easyrsa --batch revoke "$client"
				./easyrsa --batch --days=3650 gen-crl
				remove_client_ipv6_mapping "$client" || echo "WARNING: IPv6 mapping cleanup failed."
				rm -f /etc/openvpn/server/crl.pem
				rm -f /etc/openvpn/server/easy-rsa/pki/reqs/"$client".req
				rm -f /etc/openvpn/server/easy-rsa/pki/private/"$client".key
				cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
				# CRL is read with each client connection, when OpenVPN is dropped to nobody
				chown nobody:"$group_name" /etc/openvpn/server/crl.pem
				echo
				echo "$client revoked!"
			else
				echo
				echo "$client revocation aborted!"
			fi
			exit
		;;
		3)
			echo
			read -p "Confirm OpenVPN removal? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Confirm OpenVPN removal? [y/N]: " remove
			done
			if [[ "$remove" =~ ^[yY]$ ]]; then
				if [[ -f "/etc/systemd/system/$IPV6_NAT_SERVICE" ]]; then
					systemctl disable --now "$IPV6_NAT_SERVICE"
					rm -f "/etc/systemd/system/$IPV6_NAT_SERVICE" "$IPV6_NAT_HELPER"
					systemctl daemon-reload
				fi
				port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
				protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
				# Firewall tools use udp/tcp, not OpenVPN's udp6/tcp6 names.
				protocol="${protocol%6}"
				if systemctl is-active --quiet firewalld.service; then
					ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24' | grep -oE '[^ ]+$')
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --remove-port="$port"/"$protocol"
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --remove-port="$port"/"$protocol"
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
					if grep -qs "server-ipv6" /etc/openvpn/server/server.conf; then
						ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:1194:1194:1194::/64 '"'"'!'"'"' -d fddd:1194:1194:1194::/64' | grep -oE '[^ ]+$')
						firewall-cmd --zone=trusted --remove-source=fddd:1194:1194:1194::/64
						firewall-cmd --permanent --zone=trusted --remove-source=fddd:1194:1194:1194::/64
						firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
						firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
					fi
				else
					systemctl disable --now openvpn-iptables.service
					rm -f /etc/systemd/system/openvpn-iptables.service
				fi
				if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
					semanage port -d -t openvpn_port_t -p "$protocol" "$port"
				fi
				systemctl disable --now openvpn-server@server.service
				rm -f /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
				rm -f /etc/sysctl.d/99-openvpn-forward.conf /etc/sysctl.d/99-openvpn-ipv6-dualstack.conf
				if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
					rm -rf /etc/openvpn/server
					apt-get remove --purge -y openvpn
				else
					# Else, OS must be CentOS or Fedora
					dnf remove -y openvpn
					rm -rf /etc/openvpn/server
				fi
				echo
				echo "OpenVPN removed!"
			else
				echo
				echo "OpenVPN removal aborted!"
			fi
			exit
		;;
		4)
			echo
			select_existing_client "Select a client whose IPv6 exit should change:" || exit
			client="$SELECTED_CLIENT"
			if ! grep -qE '^server-ipv6[[:space:]]' /etc/openvpn/server/server.conf; then
				echo "IPv6 is not enabled on this OpenVPN server."
				exit 1
			fi
			get_public_ipv6_addresses
			if (( ${#PUBLIC_IPV6_ADDRESSES[@]} == 0 )); then
				echo "No assigned public IPv6 addresses were detected."
				exit 1
			fi
			select_client_ipv6_exit "$client"
			set_client_ipv6_exit "$client" "$SELECTED_IPV6" || exit 1
			exit
		;;
		5)
			list_client_ipv6_exits
			exit
		;;
		6)
			exit
		;;
	esac
fi
