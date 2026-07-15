#!/bin/sh
set -e

# Generate the active nftables configuration
cat <<EOF > /etc/nftables.conf
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy accept;
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
  }
  chain output {
    type filter hook output priority 0; policy accept;

    # 1. Allow loopback traffic
    oif "lo" accept

    # 2. Allow DHCP configuration requests
    udp dport 67 accept

    # 3. Allow Domain Name System (DNS) resolution
    udp dport 53 accept
    tcp dport 53 accept

    # 4. Allow Tailscale VPN traffic (CGNAT IP range and interface)
    oifname "tailscale*" accept
    ip daddr 100.64.0.0/10 accept

    # 5. Allow established & related return traffic
    ct state established,related accept

    # 6. Block internal private networks (LAN egress filter)
    ip daddr 10.0.0.0/8 drop
    ip daddr 172.16.0.0/12 drop
    ip daddr 192.168.0.0/16 drop
    ip daddr 169.254.0.0/16 drop
    ip daddr 127.0.0.0/8 drop
    ip daddr 224.0.0.0/4 drop
    ip daddr 240.0.0.0/4 drop
  }
}
EOF

# Load rules into netns kernel space
echo "[Firewall] Applying nftables configuration..."
nft -f /etc/nftables.conf

echo "[Firewall] Rules applied successfully! Active Ruleset:"
nft list ruleset

# Hold netns open indefinitely
echo "[Firewall] Security policies active. Entering keep-alive loop."
exec sleep infinity