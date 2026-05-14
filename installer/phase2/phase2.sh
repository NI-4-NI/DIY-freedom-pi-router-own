#!/usr/bin/env bash
# freedom-pi installer, phase 2
# runs once on first boot after phase 1, via freedom-pi-phase2.service
# installs Pi-hole unattended and patches its config

set -e

STATE_DIR="/etc/freedom-pi"
STATE_FILE="$STATE_DIR/install.conf"
LOG="/var/log/freedom-pi-phase2.log"

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

die() { log "ERROR: $*"; exit 1; }

[ -f "$STATE_FILE" ] || die "missing $STATE_FILE"
# shellcheck source=/dev/null
. "$STATE_FILE"

log "=== freedom-pi phase 2 starting ==="

#
# 1. wait for wlan0 to be up with IP
#
log "waiting for wlan0 to come up..."
for i in $(seq 1 60); do
  if ip -br addr show wlan0 2>/dev/null | grep -q "${WIFI_GATEWAY}"; then
    log "wlan0 up with ${WIFI_GATEWAY}"
    break
  fi
  sleep 1
done
ip -br addr show wlan0 | grep -q "${WIFI_GATEWAY}" || die "wlan0 never got ${WIFI_GATEWAY}"

#
# 1b. wait for WAN + DNS before attempting to download Pi-hole
#
log "waiting for WAN IP on eth1..."
for i in $(seq 1 60); do
  wan_ip=$(ip -br addr show eth1 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  case "$wan_ip" in
    ""|169.254.*) sleep 1; continue ;;
    *) log "eth1 up with $wan_ip"; break ;;
  esac
done

log "waiting for DNS to resolve install.pi-hole.net..."
for i in $(seq 1 60); do
  if getent hosts install.pi-hole.net >/dev/null 2>&1; then
    log "DNS OK"
    break
  fi
  sleep 1
done
getent hosts install.pi-hole.net >/dev/null 2>&1 || die "DNS never resolved install.pi-hole.net. check eth1 DHCP."

#
# 2. pre-seed Pi-hole unattended values (v6 reads setupVars.conf on fresh install)
#
log "pre-seeding /etc/pihole/setupVars.conf"
install -d -m 755 /etc/pihole
cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=wlan0
IPV4_ADDRESS=${WIFI_GATEWAY}/24
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=8.8.8.8
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
BLOCKING_ENABLED=true
DNSMASQ_LISTENING=local
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSSEC=false
REV_SERVER=false
EOF

#
# 3. install Pi-hole unattended
#
log "installing Pi-hole (unattended)..."
export PIHOLE_SKIP_OS_CHECK=true
curl -sSL https://install.pi-hole.net -o /tmp/pihole-installer.sh
bash /tmp/pihole-installer.sh --unattended
rm -f /tmp/pihole-installer.sh
log "Pi-hole install complete"

#
# 4. set admin password
#
log "setting Pi-hole admin password"
pihole setpassword "$PIHOLE_ADMIN_PW"

#
# 5. patch pihole.toml: set listeningMode=ALL so Pi-hole DNS answers on all
#    interfaces. DHCP is left disabled here; isc-dhcp-server handles it (step 8).
#
log "patching /etc/pihole/pihole.toml"
TOML=/etc/pihole/pihole.toml
[ -f "$TOML" ] || die "$TOML not found after Pi-hole install"
cp "$TOML" "${TOML}.pre-freedom-pi.bak"

python3 << PYEOF
import re

path = "$TOML"

with open(path) as f:
    content = f.read()

content = re.sub(
    r'(^\s*listeningMode\s*=\s*)"LOCAL"',
    r'\1"ALL" ### freedom-pi',
    content,
    count=1,
    flags=re.MULTILINE
)

with open(path, "w") as f:
    f.write(content)

print("pihole.toml patched")
PYEOF

log "pihole.toml patched"

#
# 6. restart pihole-FTL to pick up new config
#
log "restarting pihole-FTL"
systemctl restart pihole-FTL
sleep 3
if ! systemctl is-active --quiet pihole-FTL; then
  die "pihole-FTL failed to start after patching. check: journalctl -u pihole-FTL"
fi

#
# 7. install Webmin (browser-based management panel, port 10000)
#
log "installing Webmin..."
curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh -o /tmp/webmin-setup.sh
bash /tmp/webmin-setup.sh --force
rm -f /tmp/webmin-setup.sh
apt install -y webmin
systemctl enable --now webmin
log "Webmin installed and running on port 10000 (LAN + WiFi only)"

#
# 8. install isc-dhcp-server (Webmin manages static leases via its DHCP module)
#
log "installing isc-dhcp-server..."
DEBIAN_FRONTEND=noninteractive apt install -y isc-dhcp-server

LAN_SUBNET_NET="${LAN_GATEWAY%.*}.0"
WIFI_SUBNET_NET="${WIFI_GATEWAY%.*}.0"
WIFI_2G_SUBNET_NET="${WIFI_2G_GATEWAY%.*}.0"

cat > /etc/dhcp/dhcpd.conf << EOF
default-lease-time 86400;
max-lease-time 86400;

# LAN subnet. Add static host reservations in Webmin -> Servers -> DHCP Server.
subnet ${LAN_SUBNET_NET} netmask 255.255.255.0 {
    range ${LAN_DHCP_START} ${LAN_DHCP_END};
    option routers ${LAN_GATEWAY};
    option domain-name-servers 1.1.1.1, 1.0.0.1;
}

# WiFi 5 GHz subnet.
subnet ${WIFI_SUBNET_NET} netmask 255.255.255.0 {
    range ${WIFI_DHCP_START} ${WIFI_DHCP_END};
    option routers ${WIFI_GATEWAY};
    option domain-name-servers 1.1.1.1, 1.0.0.1;
}

# WiFi 2.4 GHz subnet.
subnet ${WIFI_2G_SUBNET_NET} netmask 255.255.255.0 {
    range ${WIFI_2G_DHCP_START} ${WIFI_2G_DHCP_END};
    option routers ${WIFI_2G_GATEWAY};
    option domain-name-servers 1.1.1.1, 1.0.0.1;
}
EOF

printf 'INTERFACESv4="eth0 wlan0 wlan_onboard"\nINTERFACESv6=""\n' > /etc/default/isc-dhcp-server

systemctl enable --now isc-dhcp-server
log "isc-dhcp-server enabled for eth0 (LAN), wlan0 (5 GHz), wlan_onboard (2.4 GHz)"

#
# 9. weekly Pi-hole update (gravity lists + binary) at Sunday 04:00
#
log "scheduling weekly pihole -up"
cat > /etc/cron.d/pihole-update << 'EOF'
# Update Pi-hole gravity lists and binary every Sunday at 04:00
0 4 * * 0 root pihole -up >> /var/log/pihole-update.log 2>&1
EOF
chmod 644 /etc/cron.d/pihole-update
log "pihole weekly update scheduled"

#
# 10. disable and clean up this oneshot
#
log "disabling phase 2 oneshot (self-destruct)"
systemctl disable freedom-pi-phase2.service
rm -f /etc/systemd/system/freedom-pi-phase2.service
systemctl daemon-reload

# leave STATE_FILE on disk for post-install inspection, but strip secrets
if [ -f "$STATE_FILE" ]; then
  sed -i 's/^PIHOLE_ADMIN_PW=.*$/PIHOLE_ADMIN_PW=<redacted>/' "$STATE_FILE"
fi

log "=== freedom-pi phase 2 complete ==="
log "admin UI: http://${WIFI_GATEWAY}/admin"
log "logs:     $LOG"
