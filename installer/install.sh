#!/usr/bin/env bash
# freedom-pi installer, phase 1
# run on a fresh Raspberry Pi OS Lite (64-bit) install with sudo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIGS_DIR="$SCRIPT_DIR/configs"
PHASE2_DIR="$SCRIPT_DIR/phase2"
STATE_DIR="/etc/freedom-pi"
STATE_FILE="$STATE_DIR/install.conf"

banner() {
  cat << 'EOF'

  +---------------------------------------+
  |   freedom-pi router installer         |
  |   Pi 5 + Pi-hole + hostapd            |
  +---------------------------------------+

EOF
}

#
# sanity
#
banner
require_root
require_pi5
require_rpios

#
# gather answers
#
log_section "configuration"

prompt_default    SSID_5G           "5 GHz WiFi name (SSID)"            "Freedom-5G"
prompt_default    SSID_2G           "2.4 GHz WiFi name (SSID)"          "Freedom"
prompt_password   WPA_PASSPHRASE    "WiFi password (min 8 chars)"
prompt_default    COUNTRY_CODE      "WiFi country code (2 letters)"     "US"
prompt_default    LAN_SUBNET        "Wired LAN subnet (x.x.x)"          "192.168.10"
prompt_default    WIFI_SUBNET       "5 GHz WiFi subnet (x.x.x)"         "192.168.2"
prompt_default    WIFI_2G_SUBNET    "2.4 GHz WiFi subnet (x.x.x)"       "192.168.3"
prompt_password   PIHOLE_ADMIN_PW   "Pi-hole admin password (min 8)"
prompt_default    DOWNSTREAM_MAC    "Downstream router MAC for DHCP reservation (Enter to skip)" ""

LAN_GATEWAY="${LAN_SUBNET}.1"
WIFI_GATEWAY="${WIFI_SUBNET}.1"
WIFI_2G_GATEWAY="${WIFI_2G_SUBNET}.1"
LAN_DHCP_START="${LAN_SUBNET}.100"
LAN_DHCP_END="${LAN_SUBNET}.200"
WIFI_DHCP_START="${WIFI_SUBNET}.100"
WIFI_DHCP_END="${WIFI_SUBNET}.200"
WIFI_2G_DHCP_START="${WIFI_2G_SUBNET}.100"
WIFI_2G_DHCP_END="${WIFI_2G_SUBNET}.200"

DOWNSTREAM_RESERVED=""
if [ -n "$DOWNSTREAM_MAC" ]; then
  DOWNSTREAM_RESERVED="${LAN_SUBNET}.2"
fi

cat << EOF

${C_BOLD}review:${C_RESET}
  5 GHz SSID:       $SSID_5G
  2.4 GHz SSID:     $SSID_2G
  country:          $COUNTRY_CODE
  LAN gateway:      $LAN_GATEWAY
  LAN DHCP range:   $LAN_DHCP_START - $LAN_DHCP_END
  WiFi 5G gateway:  $WIFI_GATEWAY
  WiFi 5G DHCP:     $WIFI_DHCP_START - $WIFI_DHCP_END
  WiFi 2G gateway:  $WIFI_2G_GATEWAY
  WiFi 2G DHCP:     $WIFI_2G_DHCP_START - $WIFI_2G_DHCP_END
$([ -n "$DOWNSTREAM_MAC" ] && printf "  Downstream MAC:   %s -> %s (reserved)\n" "$DOWNSTREAM_MAC" "$DOWNSTREAM_RESERVED")
EOF
prompt_yes_no "proceed?" y || die "aborted"

#
# MAC discovery
#
log_section "interface detection"

log_info "USB ethernet adapters found:"
mapfile -t USB_ETH < <(list_usb_ethernet)
if [ ${#USB_ETH[@]} -eq 0 ]; then
  die "no USB ethernet adapter detected. plug in the UGREEN and re-run."
fi
i=1
for line in "${USB_ETH[@]}"; do
  printf "  %d) %s\n" "$i" "$line"
  i=$((i+1))
done

if [ ${#USB_ETH[@]} -eq 1 ]; then
  UGREEN_IFACE="$(echo "${USB_ETH[0]}" | awk '{print $1}')"
  UGREEN_MAC="$(echo "${USB_ETH[0]}" | awk '{print $2}')"
  log_ok "picked as UGREEN LAN: $UGREEN_IFACE ($UGREEN_MAC)"
else
  prompt_default PICK "which number is your UGREEN (LAN)" "1"
  sel="${USB_ETH[$((PICK-1))]}"
  UGREEN_IFACE="$(echo "$sel" | awk '{print $1}')"
  UGREEN_MAC="$(echo "$sel" | awk '{print $2}')"
fi

log_info "WiFi radios found:"
mapfile -t WIFI_DEVS < <(list_wifi)
i=1
for line in "${WIFI_DEVS[@]}"; do
  mac="$(echo "$line" | awk '{print $2}')"
  tag=""
  is_builtin_wifi_mac "$mac" && tag=" (looks like Pi built-in)"
  printf "  %d) %s%s\n" "$i" "$line" "$tag"
  i=$((i+1))
done

USE_PANDA=1
if prompt_yes_no "using a Panda PAU0F (or other USB WiFi stick) for the AP?" y; then
  USE_PANDA=1
  # auto-detect panda = the one that's NOT a built-in mac prefix
  PANDA_MAC=""
  BUILTIN_WIFI_MAC=""
  for line in "${WIFI_DEVS[@]}"; do
    mac="$(echo "$line" | awk '{print $2}')"
    if is_builtin_wifi_mac "$mac"; then
      BUILTIN_WIFI_MAC="$mac"
    else
      PANDA_MAC="$mac"
    fi
  done
  if [ -z "$PANDA_MAC" ]; then
    die "could not find a non-built-in WiFi MAC. plug in the Panda and re-run."
  fi
  if [ -z "$BUILTIN_WIFI_MAC" ]; then
    log_warn "no built-in WiFi detected (2c:cf:67 or d8:3a:dd prefix). skipping wlan-onboard rename."
  fi
  log_ok "Panda WiFi MAC:    $PANDA_MAC"
  [ -n "$BUILTIN_WIFI_MAC" ] && log_ok "built-in WiFi MAC: $BUILTIN_WIFI_MAC"
else
  USE_PANDA=0
  log_ok "using Pi built-in WiFi for AP"
fi

prompt_yes_no "looks right?" y || die "aborted"

#
# install packages
#
log_section "apt install"
export DEBIAN_FRONTEND=noninteractive
apt update
apt full-upgrade -y
apt install -y dhcpcd5 hostapd nftables curl ca-certificates \
  fail2ban unattended-upgrades cockpit zram-tools

#
# swap NetworkManager for dhcpcd
#
log_section "network stack"
systemctl disable --now NetworkManager 2>/dev/null || true
systemctl enable --now dhcpcd

#
# .link files for predictable interface names
#
log_section "pinning interface names"
install -d /etc/systemd/network
substitute_vars "$CONFIGS_DIR/10-eth1.link" /etc/systemd/network/10-eth1.link \
  "UGREEN_MAC=$UGREEN_MAC"
log_ok "pinned UGREEN -> eth1 ($UGREEN_MAC)"

if [ "$USE_PANDA" -eq 1 ]; then
  substitute_vars "$CONFIGS_DIR/20-wlan0.link" /etc/systemd/network/20-wlan0.link \
    "PANDA_MAC=$PANDA_MAC"
  log_ok "pinned Panda -> wlan0 ($PANDA_MAC)"
  if [ -n "$BUILTIN_WIFI_MAC" ]; then
    substitute_vars "$CONFIGS_DIR/20-wlan-onboard.link" /etc/systemd/network/20-wlan-onboard.link \
      "BUILTIN_WIFI_MAC=$BUILTIN_WIFI_MAC"
    log_ok "pinned built-in WiFi -> wlan_onboard"
  fi
fi

#
# dhcpcd static IPs
#
log_section "dhcpcd static IPs"
if ! grep -q "freedom-pi router config" /etc/dhcpcd.conf; then
  substitute_vars "$CONFIGS_DIR/dhcpcd.conf.append" /tmp/dhcpcd.append \
    "LAN_GATEWAY=$LAN_GATEWAY" \
    "WIFI_GATEWAY=$WIFI_GATEWAY"
  cat /tmp/dhcpcd.append >> /etc/dhcpcd.conf
  rm -f /tmp/dhcpcd.append
  if [ "$USE_PANDA" -eq 1 ]; then
    printf '\ninterface wlan_onboard\nstatic ip_address=%s/24\nnohook wpa_supplicant\n' \
      "$WIFI_2G_GATEWAY" >> /etc/dhcpcd.conf
    log_ok "added wlan_onboard static IP ($WIFI_2G_GATEWAY)"
  fi
  log_ok "added static IPs to dhcpcd.conf"
else
  log_warn "dhcpcd.conf already has freedom-pi block, skipping"
fi

#
# sysctl (forwarding + buffers)
#
log_section "IP forwarding and sysctl tuning"
install -m 644 "$CONFIGS_DIR/99-router.conf" /etc/sysctl.d/99-router.conf
sysctl --system > /dev/null
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || die "ip_forward did not apply"
log_ok "IP forwarding on"

#
# nftables firewall (v4 and v6 in one ruleset)
#
log_section "firewall and NAT"
install -m 644 "$CONFIGS_DIR/nftables.conf" /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables
log_ok "nftables ruleset loaded and enabled"

#
# WiFi country code
#
log_section "WiFi country code"
raspi-config nonint do_wifi_country "$COUNTRY_CODE" || log_warn "raspi-config failed, continuing"

#
# hostapd
#
log_section "hostapd (WiFi AP)"
install -d /etc/hostapd
if [ "$USE_PANDA" -eq 1 ]; then
  HOSTAPD_SRC="$CONFIGS_DIR/hostapd-panda.conf"
else
  HOSTAPD_SRC="$CONFIGS_DIR/hostapd-builtin.conf"
fi
substitute_vars "$HOSTAPD_SRC" /etc/hostapd/hostapd-5g.conf \
  "SSID_5G=$SSID_5G" \
  "COUNTRY_CODE=$COUNTRY_CODE" \
  "WPA_PASSPHRASE=$WPA_PASSPHRASE"
chmod 600 /etc/hostapd/hostapd-5g.conf
log_ok "hostapd-5g.conf written ($SSID_5G)"

if [ "$USE_PANDA" -eq 1 ]; then
  substitute_vars "$CONFIGS_DIR/hostapd-2g.conf" /etc/hostapd/hostapd-2g.conf \
    "SSID_2G=$SSID_2G" \
    "COUNTRY_CODE=$COUNTRY_CODE" \
    "WPA_PASSPHRASE=$WPA_PASSPHRASE"
  chmod 600 /etc/hostapd/hostapd-2g.conf
  log_ok "hostapd-2g.conf written ($SSID_2G)"
  printf 'DAEMON_CONF="/etc/hostapd/hostapd-5g.conf /etc/hostapd/hostapd-2g.conf"\n' \
    > /etc/default/hostapd
else
  printf 'DAEMON_CONF="/etc/hostapd/hostapd-5g.conf"\n' > /etc/default/hostapd
fi

install -d /etc/systemd/system/hostapd.service.d
install -m 644 "$CONFIGS_DIR/unblock-rfkill.conf" /etc/systemd/system/hostapd.service.d/unblock-rfkill.conf

systemctl daemon-reload
systemctl unmask hostapd
systemctl enable hostapd
log_ok "hostapd enabled"

#
# host hardening: SSH, fail2ban, auto security updates
#
log_section "host hardening"

# SSH drop-in. If the current user has no authorized_keys file, skip
# the PasswordAuthentication=no line so we don't lock them out.
SSHD_DROPIN_SRC="$CONFIGS_DIR/sshd_freedom-pi.conf"
SSHD_DROPIN_DST="/etc/ssh/sshd_config.d/99-freedom-pi.conf"
install -d /etc/ssh/sshd_config.d

# Who ran sudo? Fall back to root if someone ran this directly as root.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
HAS_KEYS=0
if [ -n "$REAL_HOME" ] && [ -s "$REAL_HOME/.ssh/authorized_keys" ]; then
  HAS_KEYS=1
fi

install -m 644 "$SSHD_DROPIN_SRC" "$SSHD_DROPIN_DST"
if [ "$HAS_KEYS" -eq 0 ]; then
  log_warn "no authorized_keys for '$REAL_USER'. leaving password auth on so you don't get locked out."
  sed -i 's/^PasswordAuthentication.*/# PasswordAuthentication no  # skipped: no authorized_keys/' "$SSHD_DROPIN_DST"
else
  log_ok  "key found for '$REAL_USER', enforcing key-only auth"
fi

# Sanity check before restarting. If the drop-in has a typo, back it out
# instead of restarting sshd with a broken config.
if sshd -t; then
  systemctl restart ssh
  log_ok "sshd hardened (PermitRootLogin=no, MaxAuthTries=3)"
else
  log_err "sshd -t failed, removing the drop-in"
  rm -f "$SSHD_DROPIN_DST"
fi

# fail2ban ships with a working sshd jail out of the box on Debian.
systemctl enable --now fail2ban
log_ok "fail2ban enabled (sshd jail)"

# Auto security patches.
install -m 644 "$CONFIGS_DIR/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades

# Reboot settings: automatic reboot at 04:30 if a package update requires it.
install -m 644 "$CONFIGS_DIR/52freedom-pi-upgrades" /etc/apt/apt.conf.d/52freedom-pi-upgrades

# Reschedule the upgrade timer to Sunday 04:00 with up to 15 min random spread.
install -d /etc/systemd/system/apt-daily-upgrade.timer.d
install -m 644 "$CONFIGS_DIR/apt-daily-upgrade.timer.conf" \
  /etc/systemd/system/apt-daily-upgrade.timer.d/freedom-pi.conf
systemctl daemon-reload
systemctl enable --now unattended-upgrades
log_ok "unattended-upgrades enabled (Sunday 04:00, reboot 04:30 if needed)"

# Cockpit: browser-based system dashboard (services, journal, terminal).
# cockpit-networkmanager is intentionally excluded because this build uses
# dhcpcd instead of NetworkManager.
systemctl enable --now cockpit.socket
log_ok "Cockpit enabled on port 9090 (LAN + WiFi only)"

#
# log2ram: keep /var/log in RAM, flush periodically to disk
# reduces NVMe write cycles; also prevents /var/log from filling under burst logging
#
log_section "log2ram"
if ! dpkg -l log2ram &>/dev/null 2>&1; then
  log_info "adding azlux repo for log2ram..."
  curl -fsSL https://azlux.fr/repo.gpg \
    -o /usr/share/keyrings/azlux-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ bookworm main\n' \
    > /etc/apt/sources.list.d/azlux.list
  apt update -qq
  apt install -y log2ram
fi
sed -i 's/^SIZE=.*/SIZE=128M/' /etc/log2ram.conf
log_ok "log2ram configured (128M; Pi 3 A+ used 90M which proved tight)"

#
# zram: compressed swap in RAM (~512 MB on a 2GB Pi)
# reduces memory pressure when Pi-hole is loading large blocklists
#
log_section "zram swap"
if grep -q '^PERCENTAGE=' /etc/default/zramswap 2>/dev/null; then
  sed -i 's/^PERCENTAGE=.*/PERCENTAGE=25/' /etc/default/zramswap
else
  printf 'PERCENTAGE=25\n' >> /etc/default/zramswap
fi
systemctl enable --now zramswap
log_ok "zram configured (25% RAM = ~512 MB compressed swap)"

#
# systemd journal: volatile storage so journal lives in /run, not /var/log
# without this, journal writes to /var/log/journal/ which doubles memory use
# when /var/log is itself a log2ram tmpfs (hit 44M on Pi 3 A+ despite 20M cap)
#
log_section "journal limits"
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/router.conf << 'EOF'
[Journal]
Storage=volatile
SystemMaxUse=20M
RuntimeMaxUse=20M
EOF
rm -rf /var/log/journal/
systemctl restart systemd-journald
log_ok "journal set to volatile (20 MB cap, lives in /run not /var/log)"

#
# NTP: use IP addresses, not hostnames
# hostnames cause a DNS race: timesyncd starts before Pi-hole + Unbound + Stubby
# are ready. do NOT add After=network-online.target -- that conflicts with
# Before=sysinit.target in the original unit and silently prevents it starting.
#
log_section "NTP time sync"
cat > /etc/systemd/timesyncd.conf << 'EOF'
[Time]
NTP=162.159.200.1 216.239.35.0
FallbackNTP=69.9.131.124
EOF
systemctl enable systemd-timesyncd
systemctl restart systemd-timesyncd
log_ok "timesyncd configured (Cloudflare + Google IPs, no hostname DNS dependency)"

#
# Pi 5 active cooler fan curve
# fan starts at 50°C instead of the default ~67°C — better for 24/7 router duty
# speeds are PWM values (0-255); temps are milli-Celsius (50000 = 50°C)
#
log_section "Pi 5 active cooler fan curve"
if ! grep -q 'freedom-pi fan curve' /boot/firmware/config.txt 2>/dev/null; then
  cat >> /boot/firmware/config.txt << 'EOF'

# freedom-pi fan curve: active cooler starts spinning at 50°C for 24/7 router duty
dtparam=fan_temp0=50000,fan_temp0_hyst=5000,fan_temp0_speed=75
dtparam=fan_temp1=60000,fan_temp1_hyst=5000,fan_temp1_speed=125
dtparam=fan_temp2=70000,fan_temp2_hyst=5000,fan_temp2_speed=175
dtparam=fan_temp3=80000,fan_temp3_hyst=5000,fan_temp3_speed=225
EOF
  log_ok "fan curve written to config.txt (starts at 50°C)"
else
  log_warn "fan curve already in config.txt, skipping"
fi

#
# stash state for phase 2
#
log_section "staging phase 2"
install -d -m 700 "$STATE_DIR"
# use printf %q so any special chars in the admin password (", $, \, !, etc.)
# are properly escaped. sourcing this file back into bash is safe.
{
  echo "# freedom-pi install state, consumed by phase 2 on next boot"
  printf 'WIFI_GATEWAY=%q\n'         "$WIFI_GATEWAY"
  printf 'WIFI_DHCP_START=%q\n'      "$WIFI_DHCP_START"
  printf 'WIFI_DHCP_END=%q\n'        "$WIFI_DHCP_END"
  printf 'WIFI_2G_GATEWAY=%q\n'      "$WIFI_2G_GATEWAY"
  printf 'WIFI_2G_DHCP_START=%q\n'   "$WIFI_2G_DHCP_START"
  printf 'WIFI_2G_DHCP_END=%q\n'     "$WIFI_2G_DHCP_END"
  printf 'LAN_GATEWAY=%q\n'          "$LAN_GATEWAY"
  printf 'LAN_DHCP_START=%q\n'       "$LAN_DHCP_START"
  printf 'LAN_DHCP_END=%q\n'         "$LAN_DHCP_END"
  printf 'PIHOLE_ADMIN_PW=%q\n'      "$PIHOLE_ADMIN_PW"
  printf 'DOWNSTREAM_MAC=%q\n'       "${DOWNSTREAM_MAC:-}"
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

# drop phase 2 script + systemd oneshot in place
install -m 755 "$PHASE2_DIR/phase2.sh" "$STATE_DIR/phase2.sh"
install -m 644 "$PHASE2_DIR/freedom-pi-phase2.service" /etc/systemd/system/freedom-pi-phase2.service

# stage DNS chain configs for phase 2 to copy into place after reboot
install -m 644 "$CONFIGS_DIR/stubby.yml"          "$STATE_DIR/stubby.yml"
install -m 644 "$CONFIGS_DIR/unbound-pihole.conf" "$STATE_DIR/unbound-pihole.conf"
systemctl daemon-reload
systemctl enable freedom-pi-phase2.service
log_ok "phase 2 oneshot installed"

#
# bake .link files into initramfs
#
log_section "updating initramfs"
update-initramfs -u
log_ok "initramfs updated"

#
# done phase 1
#
log_section "phase 1 complete"
cat << EOF

next up: the Pi will reboot and phase 2 runs automatically. phase 2 starts
hostapd, installs Pi-hole, and patches its config. takes about 5 minutes.

${C_YELLOW}${C_BOLD}heads up on SSH:${C_RESET}
  WAN SSH is off. After the reboot you reach the Pi over LAN or WiFi:
    LAN (eth1):     ssh $REAL_USER@${LAN_GATEWAY}
    WiFi 5 GHz:     ssh $REAL_USER@${WIFI_GATEWAY}
    WiFi 2.4 GHz:   ssh $REAL_USER@${WIFI_2G_GATEWAY}
  If you were SSH'd in via eth0 plugged into your modem, move
  your cable to eth1 (UGREEN, LAN port) or join WiFi after the reboot.
  Also: root SSH is off, MaxAuthTries is 3, fail2ban is watching.

after phase 2, SSH back in and check:
  systemctl is-active hostapd pihole-FTL dhcpcd fail2ban unattended-upgrades
  ip addr show wlan0     # should show ${WIFI_GATEWAY}
  ip addr show eth1      # should show ${LAN_GATEWAY}
  sudo fail2ban-client status sshd
  sudo nft list ruleset  # nftables rules loaded (v4 + v6)

EOF

if prompt_yes_no "reboot now?" y; then
  log_info "rebooting in 5 seconds..."
  sleep 5
  systemctl reboot
else
  log_warn "reboot manually when ready (sudo reboot) to trigger phase 2"
fi
