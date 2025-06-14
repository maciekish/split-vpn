#!/bin/sh
# This script adds the iptables rules for the VPN. It is usually called by updown.sh script.

# Exit if an error is encountered
set -e 

# ./add-vpn-iptables-rules.sh [pre-up/up/down/force-down] [tun_dev]

CHAINS="mangle:PREROUTING mangle:POSTROUTING mangle:FORWARD mangle:OUTPUT nat:PREROUTING nat:POSTROUTING filter:INPUT filter:FORWARD"

# Create the iptables chains
create_chains() {
	for entry in ${CHAINS}; do
		table=$(echo ${entry} | cut -d':' -f1)
		chain=$(echo ${entry} | cut -d':' -f2)
		iptables -w -t ${table} -N ${PREFIX}${chain} >/dev/null 2>&1 || true
		ip6tables -w -t ${table} -N ${PREFIX}${chain} >/dev/null 2>&1 || true
		add_rule both ${table} "${chain} -j ${PREFIX}${chain}" noprefix
	done
}

# Delete the iptables chains
delete_chains() {
	for entry in ${CHAINS}; do
		table=$(echo ${entry} | cut -d':' -f1)
		chain=$(echo ${entry} | cut -d':' -f2)
		iptables -w -t ${table} -D ${chain} -j ${PREFIX}${chain} >/dev/null 2>&1 || true
		ip6tables -w -t ${table} -D ${chain} -j ${PREFIX}${chain} >/dev/null 2>&1 || true
		iptables -w -t ${table} -F ${PREFIX}${chain} >/dev/null 2>&1 || true
		ip6tables -w -t ${table} -F ${PREFIX}${chain} >/dev/null 2>&1 || true
		iptables -w -t ${table} -X ${PREFIX}${chain} >/dev/null 2>&1 || true
		ip6tables -w -t ${table} -X ${PREFIX}${chain} >/dev/null 2>&1 || true
	done
}

# add_rule IPV4/IPV6/both TABLE "RULE" (prefix=noprefix)
# Add an iptables rule. 
add_rule() {
	if [ "$4" = "noprefix" ]; then
		prefix=""
	else
		prefix=${PREFIX}
	fi
	if [ "$1" = "IPV4" ]; then
		iptables -w -t $2 -C ${prefix}$3 >/dev/null 2>&1 || iptables -w -t $2 -A ${prefix}$3
	elif [ "$1" = "IPV6" ]; then
		ip6tables -w -t $2 -C ${prefix}$3 >/dev/null 2>&1 || ip6tables -w -t $2 -A ${prefix}$3
	else
		iptables -w -t $2 -C ${prefix}$3 >/dev/null 2>&1 || iptables -w -t $2 -A ${prefix}$3
		ip6tables -w -t $2 -C ${prefix}$3 >/dev/null 2>&1 || ip6tables -w -t $2 -A ${prefix}$3
	fi
}

# Get the first IPv4 DNS server provided by the VPN server's DHCP options if option is set.
# These options are found in environment variables foreign_option_i for openvpn.
get_dns() {
	if [ "${DNS_IPV4_IP}" = "DHCP" ]; then
		DNS_IPV4_IP=""
		if [ "${VPN_PROVIDER}" = "openvpn" ]; then
			# Only check a maximum of 1000 options. Usually only get 1 or 2.
			for i in $(seq 1 1000); do
				foreign_option_i=$(eval echo \$foreign_option_$i)
				if [ -z "${foreign_option_i}" ]; then
					break
				fi
				dns=$(echo "${foreign_option_i}" | sed -En s/".*dhcp-option DNS ([0-9\.]+).*"/"\1"/p)
				if [ -z "${dns}" ]; then
					continue
				fi
				DNS_IPV4_IP="${dns}"
				DNS_IPV4_PORT=53
				break
			done
		elif [ "${VPN_PROVIDER}" = "openconnect" ]; then
			for i in ${INTERNAL_IP4_DNS}; do
				DNS_IPV4_IP="$i"
				DNS_IPV4_PORT=53
				break
			done
		fi
	fi
	if [ "${DNS_IPV6_IP}" = "DHCP" ]; then
		DNS_IPV6_IP=""
		if [ "${VPN_PROVIDER}" = "openconnect" ]; then
			for i in ${INTERNAL_IP6_DNS}; do
				DNS_IPV6_IP="$i"
				DNS_IPV6_PORT=53
				break
			done
		fi
	fi
}

# add_ipset_map_rule force/exempt ipset_map
add_ipset_rule() {
	for ipset_map in $2; do
		ipset=$(echo "$ipset_map" | cut -d':' -f1)
		map=$(echo "$ipset_map" | cut -d':' -f2)
		ipset_type=$(ipset list "$ipset" | grep "Type:" | sed -E s/"Type: (.*)"/"\1"/g)
		if [ "$1" = "force" ]; then
			rule="PREROUTING -m set --match-set ${ipset} ${map} -j MARK --set-xmark ${MARK}"
		else
			rule="PREROUTING -m set --match-set ${ipset} ${map} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
		if [ "$ipset_type" = "list:set" ]; then 
			add_rule both mangle "$rule"
		else
			family=$(ipset list "$ipset" | grep "Header:" | sed -E s/".*family (inet6?) .*"/"\1"/g)
			if [ "$family" = "inet" ]; then
				add_rule IPV4 mangle "$rule"
			elif [ "$family" = "inet6" ]; then
				add_rule IPV6 mangle "$rule"
			else
				echo "ERROR: Not adding $ipset with unknown family: $family."
			fi
		fi
	done
}

# Add iptables rules
add_iptables_rules() {
	# Force traffic through VPN for each forced interface
	for interface in ${FORCED_SOURCE_INTERFACE}; do
		add_rule both mangle "PREROUTING -i ${interface} -j MARK --set-xmark ${MARK}"
	done

	# Force traffic through VPN for each forced IPv4 or IPv6 source
	for ip in ${FORCED_SOURCE_IPV4}; do
		add_rule IPV4 mangle "PREROUTING -s ${ip} -j MARK --set-xmark ${MARK}"
	done
	for ip in ${FORCED_SOURCE_IPV6}; do
		add_rule IPV6 mangle "PREROUTING -s ${ip} -j MARK --set-xmark ${MARK}"
	done

	# Force traffic through VPN for each forced mac source
	for mac in ${FORCED_SOURCE_MAC}; do
		add_rule both mangle "PREROUTING -m mac --mac-source ${mac} -j MARK --set-xmark ${MARK}"
	done

	# Force source IP:PORT for IPv4 and IPv6
	for entry in ${FORCED_SOURCE_IPV4_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_ip=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV4 mangle "PREROUTING -p tcp -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
			add_rule IPV4 mangle "PREROUTING -p udp -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		else
			add_rule IPV4 mangle "PREROUTING -p ${proto} -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		fi
	done
	for entry in ${FORCED_SOURCE_IPV6_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_ip=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV6 mangle "PREROUTING -p tcp -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
			add_rule IPV6 mangle "PREROUTING -p udp -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		else
			add_rule IPV6 mangle "PREROUTING -p ${proto} -s ${source_ip} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		fi
	done

	# Force destination IP:PORT for IPv4 and IPv6
	for entry in ${FORCED_DEST_IPV4_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dest_ip=$(echo "$entry"   | cut -d'-' -f2)
		dports=$(echo "$entry"    | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV4 mangle "PREROUTING -p tcp -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
			add_rule IPV4 mangle "PREROUTING -p udp -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
		else
			add_rule IPV4 mangle "PREROUTING -p ${proto} -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
		fi
	done

	for entry in ${FORCED_DEST_IPV6_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dest_ip=$(echo "$entry"   | cut -d'-' -f2)
		dports=$(echo "$entry"    | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV6 mangle "PREROUTING -p tcp -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
			add_rule IPV6 mangle "PREROUTING -p udp -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
		else
			add_rule IPV6 mangle "PREROUTING -p ${proto} -d ${dest_ip} -m multiport --dports ${dports} -j MARK --set-xmark ${MARK}"
		fi
	done

	# Force source MAC:PORT
	for entry in ${FORCED_SOURCE_MAC_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_mac=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule both mangle "PREROUTING -p tcp -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
			add_rule both mangle "PREROUTING -p udp -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		else
			add_rule both mangle "PREROUTING -p ${proto} -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -j MARK --set-xmark ${MARK}"
		fi
	done

	# Force traffic through VPN for each destination
	for ip in ${FORCED_DESTINATIONS_IPV4}; do
		add_rule IPV4 mangle "PREROUTING -d ${ip} -j MARK --set-xmark ${MARK}"
	done
	for ip in ${FORCED_DESTINATIONS_IPV6}; do
		add_rule IPV6 mangle "PREROUTING -d ${ip} -j MARK --set-xmark ${MARK}"
	done

	# Force traffic through VPN for each ipset
	add_ipset_rule force "${FORCED_IPSETS}"

	echo "${CUSTOM_FORCED_RULES_IPV4}" | while read -r rule; do
		rule=$(echo "$rule" | xargs)
		if [ -n "$rule" ]; then
 			add_rule IPV4 mangle "PREROUTING $rule -j MARK --set-xmark ${MARK}"
		fi
	done
	echo "${CUSTOM_FORCED_RULES_IPV6}" | while read -r rule; do
		rule=$(echo "$rule" | xargs)
		if [ -n "$rule" ]; then
 			add_rule IPV6 mangle "PREROUTING $rule -j MARK --set-xmark ${MARK}"
		fi
	done

	# Force traffic through VPN for local output interfaces
	if [ "$state" != "pre-up" ]; then
		for intfc in ${FORCED_LOCAL_INTERFACE}; do 
			add_rule both mangle "OUTPUT -o ${intfc} -j MARK --set-xmark ${MARK}"
		done
	fi

	# Exempt sources from VPN
	for ip in ${EXEMPT_SOURCE_IPV4}; do
		add_rule IPV4 mangle "PREROUTING -s ${ip} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done
	for ip in ${EXEMPT_SOURCE_IPV6}; do
		add_rule IPV6 mangle "PREROUTING -s ${ip} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done
	for mac in ${EXEMPT_SOURCE_MAC}; do
		add_rule both mangle "PREROUTING -m mac --mac-source ${mac} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done

	# Exempt source IP:PORT for IPv4 and IPv6
	for entry in ${EXEMPT_SOURCE_IPV4_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_ip=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV4 mangle "PREROUTING -p tcp -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
			add_rule IPV4 mangle "PREROUTING -p udp -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		else
			add_rule IPV4 mangle "PREROUTING -p ${proto} -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done
	for entry in ${EXEMPT_SOURCE_IPV6_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_ip=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV6 mangle "PREROUTING -p tcp -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
			add_rule IPV6 mangle "PREROUTING -p udp -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		else
			add_rule IPV6 mangle "PREROUTING -p ${proto} -s ${source_ip} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done

	for entry in ${EXEMPT_DEST_IPV4_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dest_ip=$(echo "$entry"   | cut -d'-' -f2)
		dports=$(echo "$entry"    | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV4 mangle \
				"PREROUTING -p tcp -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
			add_rule IPV4 mangle \
				"PREROUTING -p udp -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		else
			add_rule IPV4 mangle \
				"PREROUTING -p ${proto} -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done

	for entry in ${EXEMPT_DEST_IPV6_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dest_ip=$(echo "$entry"   | cut -d'-' -f2)
		dports=$(echo "$entry"    | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule IPV6 mangle \
				"PREROUTING -p tcp -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
			add_rule IPV6 mangle \
				"PREROUTING -p udp -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		else
			add_rule IPV6 mangle \
				"PREROUTING -p ${proto} -d ${dest_ip} -m multiport --dports ${dports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done

	# Exempt source MAC:PORT from VPN
	for entry in ${EXEMPT_SOURCE_MAC_PORT}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		source_mac=$(echo "$entry" | cut -d'-' -f2)
		sports=$(echo "$entry" | cut -d'-' -f3)
		if [ "$proto" = "both" ]; then
			add_rule both mangle "PREROUTING -p tcp -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
			add_rule both mangle "PREROUTING -p udp -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		else
			add_rule both mangle "PREROUTING -p ${proto} -m mac --mac-source ${source_mac} -m multiport --sports ${sports} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done

	# Exempt ipsets from VPN
	add_ipset_rule exempt "${EXEMPT_IPSETS}"

	# Exempt the local VPN IPs
	for addr in $(ip a show dev ${dev} 2>/dev/null | sed -En s/".*inet ([^ \/]+)(\/[0-9]+)? .*"/"\1"/p); do
		add_rule IPV4 mangle "PREROUTING -d ${addr} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done
	for addr in $(ip a show dev ${dev} 2>/dev/null | sed -En s/".*inet6 ([^ \/]+)(\/[0-9]+)? .*"/"\1"/p | grep -Ev "^fe80"); do
		add_rule IPV6 mangle "PREROUTING -d ${addr} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done

	# Exempt IPv4/IPv6 destinations from VPN
	for dest in ${EXEMPT_DESTINATIONS_IPV4}; do
		add_rule IPV4 mangle "PREROUTING -d ${dest} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done
	for dest in ${EXEMPT_DESTINATIONS_IPV6}; do
		add_rule IPV6 mangle "PREROUTING -d ${dest} -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
	done

	echo "${CUSTOM_EXEMPT_RULES_IPV4}" | while read -r rule; do
		rule=$(echo "$rule" | xargs)
		if [ -n "$rule" ]; then
 			add_rule IPV4 mangle "PREROUTING $rule -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done
	echo "${CUSTOM_EXEMPT_RULES_IPV6}" | while read -r rule; do
		rule=$(echo "$rule" | xargs)
		if [ -n "$rule" ]; then
 			add_rule IPV6 mangle "PREROUTING $rule -m mark --mark ${MARK} -j MARK --set-xmark 0x0"
		fi
	done

	# Set MSS clamping for packets leaving the VPN tunnel
	if [ -n "${MSS_CLAMPING_IPV4}" ]; then
		add_rule IPV4 mangle "FORWARD -o ${dev} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS_CLAMPING_IPV4}"
	fi
	if [ -n "${MSS_CLAMPING_IPV6}" ]; then
		add_rule IPV6 mangle "FORWARD -o ${dev} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS_CLAMPING_IPV6}"
	fi

	enable_masq_ipv4=1
	enable_masq_ipv6=1
	# Masquerade output traffic from VPN interface (dynamic SNAT)
	for src in ${BYPASS_MASQUERADE_IPV4}; do
		if [ "$src" = "ALL" ]; then
			enable_masq_ipv4=0
			break
		fi
		add_rule IPV4 nat "POSTROUTING -o ${dev} -s ${src} -m mark --mark ${MARK} -j ACCEPT"
	done
	for src in ${BYPASS_MASQUERADE_IPV6}; do
		if [ "$src" = "ALL" ]; then
			enable_masq_ipv6=0
			break
		fi
		add_rule IPV6 nat "POSTROUTING -o ${dev} -s ${src} -m mark --mark ${MARK} -j ACCEPT"
	done
	if [ "$enable_masq_ipv4" = "1" ]; then
		add_rule IPV4 nat "POSTROUTING -o ${dev} -m mark --mark ${MARK} -j MASQUERADE"
	fi
	if [ "$enable_masq_ipv6" = "1" ]; then
		add_rule IPV6 nat "POSTROUTING -o ${dev} -m mark --mark ${MARK} -j MASQUERADE"
	fi

	# Force DNS from environment variables or REJECT VPN DNS traffic.
	get_dns
	for proto in udp tcp; do
		if [ "${DNS_IPV4_IP}" = "REJECT" ]; then
			add_rule IPV4 filter "INPUT -m mark --mark ${MARK} -p ${proto} --dport 53 -j REJECT"
			add_rule IPV4 filter "FORWARD -m mark --mark ${MARK} -p ${proto} --dport 53 -j REJECT"
		elif [ -n "${DNS_IPV4_IP}" ]; then
			add_rule IPV4 nat "PREROUTING -m mark --mark ${MARK} -p ${proto} ! -s ${DNS_IPV4_IP} ! -d ${DNS_IPV4_IP} --dport 53 -j DNAT --to ${DNS_IPV4_IP}:${DNS_IPV4_PORT:-53}"
			if [ -n "${DNS_IPV4_INTERFACE}" ]; then
				add_rule IPV4 mangle "FORWARD -m mark --mark ${MARK} -d ${DNS_IPV4_IP} -p ${proto} --dport ${DNS_IPV4_PORT:-53} -j MARK --set-xmark 0x0"
				ip route replace ${DNS_IPV4_IP} dev ${DNS_IPV4_INTERFACE} table ${ROUTE_TABLE}
			fi
		fi
		if [ "${DNS_IPV6_IP}" = "REJECT" ]; then
			add_rule IPV6 filter "INPUT -m mark --mark ${MARK} -p ${proto} --dport 53 -j REJECT"
			add_rule IPV6 filter "FORWARD -m mark --mark ${MARK} -p ${proto} --dport 53 -j REJECT"
		elif [ -n "${DNS_IPV6_IP}" ]; then
			add_rule IPV6 nat "PREROUTING -m mark --mark ${MARK} -p ${proto} ! -s ${DNS_IPV6_IP} ! -d ${DNS_IPV6_IP} --dport 53 -j DNAT --to [${DNS_IPV6_IP}]:${DNS_IPV6_PORT:-53}"
			if [ -n "${DNS_IPV6_INTERFACE}" ]; then
				add_rule IPV6 mangle "FORWARD -m mark --mark ${MARK} -d ${DNS_IPV6_IP} -p ${proto} --dport ${DNS_IPV6_PORT:-53} -j MARK --set-xmark 0x0"
				ip -6 route replace ${DNS_IPV6_IP} dev ${DNS_IPV6_INTERFACE} table ${ROUTE_TABLE}
			fi
		fi
	done

	# Forward ports on VPN side for IPv4 or IPv6 entries
	for entry in ${PORT_FORWARDS_IPV4}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dport_vpn=$(echo "$entry" | cut -d'-' -f2)
		dest_ip=$(echo "$entry" | cut -d'-' -f3)
		dport=$(echo "$entry" | cut -d'-' -f4)
		if [ "$proto" = "both" ]; then
			add_rule IPV4 nat "PREROUTING -i ${dev} -p tcp --dport ${dport_vpn} -j DNAT --to-destination ${dest_ip}:${dport}"
			add_rule IPV4 nat "PREROUTING -i ${dev} -p udp --dport ${dport_vpn} -j DNAT --to-destination ${dest_ip}:${dport}"
		else
			add_rule IPV4 nat "PREROUTING -i ${dev} -p ${proto} --dport ${dport_vpn} -j DNAT --to-destination ${dest_ip}:${dport}"
		fi
	done
	for entry in ${PORT_FORWARDS_IPV6}; do
		proto=$(echo "$entry" | cut -d'-' -f1)
		dport_vpn=$(echo "$entry" | cut -d'-' -f2)
		dest_ip=$(echo "$entry" | cut -d'-' -f3)
		dport=$(echo "$entry" | cut -d'-' -f4)
		if [ "$proto" = "both" ]; then
			add_rule IPV6 nat "PREROUTING -i ${dev} -p tcp --dport ${dport_vpn} -j DNAT --to-destination [${dest_ip}]:${dport}"
			add_rule IPV6 nat "PREROUTING -i ${dev} -p udp --dport ${dport_vpn} -j DNAT --to-destination [${dest_ip}]:${dport}"
		else
			add_rule IPV6 nat "PREROUTING -i ${dev} -p ${proto} --dport ${dport_vpn} -j DNAT --to-destination [${dest_ip}]:${dport}"
		fi
	done
}

# Add the iptables kill switch
add_killswitch() {
	# Create the custom chain
	iptables -w -t filter -N ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	ip6tables -w -t filter -N ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	add_rule both filter "FORWARD -j ${PREFIX}KILLSWITCH" noprefix

	# Reject all VPN traffic (marked) that doesn't go out of the VPN interface
	add_rule both filter "KILLSWITCH -m mark --mark ${MARK} ! -o ${dev} -j REJECT"
}

# Delete the iptables kill switch
delete_killswitch() {
	iptables -w -t filter -D OUTPUT -j ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	ip6tables -w -t filter -D OUTPUT -j ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	iptables -w -t filter -D FORWARD -j ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	ip6tables -w -t filter -D FORWARD -j ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	iptables -w -t filter -F ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	ip6tables -w -t filter -F ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	iptables -w -t filter -X ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
	ip6tables -w -t filter -X ${PREFIX}KILLSWITCH >/dev/null 2>&1 || true
}

delete_dns_routes() {
	if [ -n "${DNS_IPV4_INTERFACE}" ]; then
		ip route del "${DNS_IPV4_IP}" table "${ROUTE_TABLE}" || true
	fi
	if [ -n "${DNS_IPV6_INTERFACE}" ]; then
		ip -6 route del "${DNS_IPV6_IP}" table "${ROUTE_TABLE}" || true
	fi
}

# If configuration variables are not present, source the config file from the PWD.
if [ -z "${MARK}" ]; then
	. ./vpn.conf
fi

# Default to tun0 if no device name was passed to this script
if [ -z "$2" ]; then
	dev=tun0
else
	dev="$2"
fi

state="$1"

# When this script is called from updown.sh, first argument is either up or down.
if [ "$state" = "pre-up" -o "$state" = "up" ]; then
	if [ "${KILLSWITCH}" = 1 ]; then
		add_killswitch
	fi
	create_chains
	add_iptables_rules
elif [ "$state" = "down" ]; then
	if [ "${REMOVE_KILLSWITCH_ON_EXIT}" = 1 ]; then
		delete_chains
		delete_killswitch
		delete_dns_routes
	fi
elif [ "$state" = "force-down" ]; then
	delete_chains
	delete_killswitch
	delete_dns_routes
fi

# Flush conntrack if forcing any local interfaces
if [ -n "$FORCED_LOCAL_INTERFACE" ]; then
	conntrack -F >/dev/null 2>&1
fi
