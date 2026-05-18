#!/usr/bin/env bash
# freedom-pi installer, phase 2
# runs once on first boot after phase 1, via freedom-pi-phase2.service

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
# 1b. wait for WAN + DNS before attempting to download anything
#
log "waiting for WAN IP on eth0..."
for i in $(seq 1 60); do
  wan_ip=$(ip -br addr show eth0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  case "$wan_ip" in
    ""|169.254.*) sleep 1; continue ;;
    *) log "eth0 up with $wan_ip"; break ;;
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
getent hosts install.pi-hole.net >/dev/null 2>&1 || die "DNS never resolved install.pi-hole.net. check eth0 DHCP."

#
# 2. install Stubby (DNS-over-TLS) and Unbound (local caching resolver)
#    Stubby must start before Unbound because Unbound forwards to it.
#
log "installing stubby and unbound..."
apt install -y stubby unbound

log "writing Stubby config (DoT to Cloudflare + Quad9)..."
install -d -m 755 /etc/stubby
install -m 644 "$STATE_DIR/stubby.yml" /etc/stubby/stubby.yml
systemctl enable --now stubby
sleep 2
systemctl is-active --quiet stubby || die "stubby failed to start"
log "stubby running on 127.0.0.1:5453"

log "writing Unbound config (caching forwarder -> stubby)..."
install -d -m 755 /etc/unbound/unbound.conf.d
install -m 644 "$STATE_DIR/unbound-pihole.conf" /etc/unbound/unbound.conf.d/pihole.conf
systemctl enable --now unbound
sleep 2
systemctl is-active --quiet unbound || die "unbound failed to start"
log "unbound running on 127.0.0.1:5335"

#
# 3. pre-seed Pi-hole unattended values
#    DNS upstream points at Unbound (127.0.0.1#5335), which is already running.
#
log "pre-seeding /etc/pihole/setupVars.conf"
install -d -m 755 /etc/pihole
cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=wlan0
IPV4_ADDRESS=${WIFI_GATEWAY}/24
PIHOLE_DNS_1=127.0.0.1#5335
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
# 4. install Pi-hole unattended
#
log "installing Pi-hole (unattended)..."
export PIHOLE_SKIP_OS_CHECK=true
curl -sSL https://install.pi-hole.net -o /tmp/pihole-installer.sh
bash /tmp/pihole-installer.sh --unattended
rm -f /tmp/pihole-installer.sh
log "Pi-hole install complete"

#
# 5. set admin password
#
log "setting Pi-hole admin password"
pihole setpassword "$PIHOLE_ADMIN_PW"

#
# 6. restore Teleporter backup if one was placed at /boot/firmware/ before install
#    Done before the pihole.toml patch so our settings win over anything in the backup.
#
TELEPORTER_SRC="/boot/firmware/pihole-teleporter.tar.gz"
if [ -f "$TELEPORTER_SRC" ]; then
  log "Teleporter backup found at $TELEPORTER_SRC, restoring..."
  if pihole teleporter import "$TELEPORTER_SRC" 2>/dev/null; then
    log "Teleporter restore complete"
  else
    log "WARNING: pihole teleporter import failed, trying legacy command..."
    pihole -a -t "$TELEPORTER_SRC" 2>/dev/null || \
      log "WARNING: Teleporter restore failed. Import manually from the admin UI."
  fi
else
  log "no Teleporter backup found at $TELEPORTER_SRC, skipping"
fi

#
# 7. patch pihole.toml:
#    - listeningMode=ALL so Pi-hole DNS answers on all interfaces
#    - DNS upstreams = Unbound on 127.0.0.1:5335
#    - DHCP stays disabled (isc-dhcp-server handles it)
#    Applied after Teleporter restore so our settings take precedence.
#
log "patching /etc/pihole/pihole.toml"
TOML=/etc/pihole/pihole.toml
[ -f "$TOML" ] || die "$TOML not found after Pi-hole install"
cp "$TOML" "${TOML}.pre-freedom-pi.bak"

python3 << PYEOF
import re, sys

path = "$TOML"

with open(path) as f:
    content = f.read()

# listeningMode: LOCAL -> ALL
n1 = len(re.findall(r'^\s*listeningMode\s*=', content, re.MULTILINE))
content = re.sub(
    r'(^\s*listeningMode\s*=\s*)"LOCAL"',
    r'\1"ALL" ### freedom-pi',
    content, count=1, flags=re.MULTILINE
)

# DNS upstreams -> Unbound
n2 = len(re.findall(r'^\s*upstreams\s*=', content, re.MULTILINE))
content = re.sub(
    r'(^\s*upstreams\s*=\s*)\[[^\]]*\]',
    r'\1["127.0.0.1#5335"] ### freedom-pi',
    content, count=1, flags=re.MULTILINE
)

# FTL NTP: replace pool.ntp.org hostname with Cloudflare IP.
# Pi-hole v6 has its own NTP client separate from systemd-timesyncd.
# pool.ntp.org causes the same DNS race on boot as timesyncd would.
n3 = len(re.findall(r'^\s*server\s*=\s*"pool\.ntp\.org"', content, re.MULTILINE))
content = re.sub(
    r'(^\s*server\s*=\s*)"pool\.ntp\.org"',
    r'\1"162.159.200.1" ### freedom-pi',
    content, count=1, flags=re.MULTILINE
)

# DB retention: default 365 days bloats the FTL database to multiple GB
# on a busy network over time. 30 days is plenty for query history.
n4 = len(re.findall(r'^\s*maxDBdays\s*=', content, re.MULTILINE))
content = re.sub(
    r'(^\s*maxDBdays\s*=\s*)\d+',
    r'\g<1>30 ### freedom-pi',
    content, count=1, flags=re.MULTILINE
)

with open(path, "w") as f:
    f.write(content)

if n1 == 0:
    sys.stderr.write("warning: listeningMode key not found\n")
if n2 == 0:
    sys.stderr.write("warning: upstreams key not found\n")
if n3 == 0:
    sys.stderr.write("warning: ntp server key not found (may already be an IP)\n")
if n4 == 0:
    sys.stderr.write("warning: maxDBdays key not found\n")
print("pihole.toml patched")
PYEOF

log "pihole.toml patched"

#
# 8. restart pihole-FTL to pick up new config
#
log "restarting pihole-FTL"
systemctl restart pihole-FTL
sleep 3
if ! systemctl is-active --quiet pihole-FTL; then
  die "pihole-FTL failed to start after patching. check: journalctl -u pihole-FTL"
fi

#
# 9. logrotate for Pi-hole
#    Pi-hole v6 ships no native logrotate entry. copytruncate is required
#    because pihole-FTL holds the log file open; standard rotation (rename+reopen)
#    silently fails without it.
#
log "writing /etc/logrotate.d/pihole"
cat > /etc/logrotate.d/pihole << 'EOF'
/var/log/pihole/pihole.log {
    weekly
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
log "pihole logrotate configured (weekly, 3 rotations, copytruncate)"

#
# 10. install Webmin (browser-based management panel, port 10000)
#
log "installing Webmin..."
curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh -o /tmp/webmin-setup.sh
bash /tmp/webmin-setup.sh --force
rm -f /tmp/webmin-setup.sh
apt install -y webmin
systemctl enable --now webmin
log "Webmin installed and running on port 10000 (LAN + WiFi only)"

#
# 11. install isc-dhcp-server (Webmin manages static leases via its DHCP module)
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

if [ -n "${DOWNSTREAM_MAC:-}" ]; then
  DOWNSTREAM_IP="${LAN_GATEWAY%.*}.2"
  cat >> /etc/dhcp/dhcpd.conf << EOF

# Downstream router (Cudy AX3000) static reservation.
# Fixed IP lets firewall rules and FAILOVER.md reference a known address.
host downstream {
    hardware ethernet ${DOWNSTREAM_MAC};
    fixed-address ${DOWNSTREAM_IP};
}
EOF
  log "Downstream router DHCP reservation: $DOWNSTREAM_MAC -> $DOWNSTREAM_IP"
fi

printf 'INTERFACESv4="eth1 wlan0 wlan_onboard"\nINTERFACESv6=""\n' > /etc/default/isc-dhcp-server

systemctl enable --now isc-dhcp-server
log "isc-dhcp-server enabled for eth1 (LAN), wlan0 (5 GHz), wlan_onboard (2.4 GHz)"

#
# 12. weekly Pi-hole update (gravity lists + binary) at Sunday 04:00
#
log "scheduling weekly pihole -up"
cat > /etc/cron.d/pihole-update << 'EOF'
# Update Pi-hole gravity lists and binary every Sunday at 04:00
0 4 * * 0 root pihole -up >> /var/log/pihole-update.log 2>&1
EOF
chmod 644 /etc/cron.d/pihole-update
log "pihole weekly update scheduled"

#
# 13. disable and clean up this oneshot
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
log "Pi-hole admin:  http://${WIFI_GATEWAY}/admin"
log "Cockpit:        http://${LAN_GATEWAY}:9090"
log "Webmin:         http://${LAN_GATEWAY}:10000"
log "DNS chain:      Pi-hole -> Unbound (5335) -> Stubby (5453) -> Cloudflare/Quad9 DoT"
log "logs:           $LOG"
