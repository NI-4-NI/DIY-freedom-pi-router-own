# Session Handoff

Everything needed to pick up where this session left off.

---

## What this project is

A fork of 0xXyc/DIY-freedom-pi-router, customized for a specific hardware build.
The installer turns a Raspberry Pi 5 into a home router with Pi-hole, encrypted DNS,
dual-band WiFi, and a cascade-ready failover setup.

Fork repo: https://github.com/NI-4-NI/DIY-freedom-pi-router-own

---

## Hardware

- Raspberry Pi 5 (2 GB RAM)
- Official Raspberry Pi M.2 HAT + Kioxia 128 GB NVMe (boots from NVMe, no microSD)
- Pi 5 built-in 1 GbE ethernet = **eth0 = WAN** (connects to modem)
- UGREEN 1 GbE USB-A ethernet adapter = **eth1 = LAN** (connects to switch/downstream router)
- Panda PAU0F AXE3000 (MT7921au / mt76 driver) = **wlan0** = 5 GHz AP
- Pi built-in WiFi = **wlan_onboard** = 2.4 GHz AP (US only, 2.4 + 5 GHz)

**This is the opposite of the upstream repo** (upstream uses USB = WAN, built-in = LAN).

Network plan:
- Pi upstairs: runs router, Pi-hole, both WiFi bands
- Nighthawk downstream on Pi eth1: runs its own subnet for downstairs
- XB8 Comcast gateway: in bridge mode (modem only) during Pi operation

---

## DNS chain

Pi-hole -> Unbound (127.0.0.1:5335) -> Stubby (127.0.0.1:5453) -> Cloudflare/Quad9 DoT

---

## Everything committed (full history)

```
ccbb86b  Fix root README: correct eth0/eth1 orientation, NVMe hardware, current installer steps
aa78fc5  Add FAILOVER.md and update installer README
050794f  Phase 2: FTL NTP IP patch, DB retention 30d, logrotate copytruncate, Nighthawk DHCP reservation
7c50235  Phase 1: log2ram, zram, journald limits, IP-only NTP, WAN DHCP hardening, Nighthawk MAC prompt
d475089  Point bootstrap at fork repo (NI-4-NI/DIY-freedom-pi-router-own)
8ae5ce9  Step 6: confirm NVMe boot compatibility, update hardware docs
481d361  Add DNS chain: Pi-hole -> Unbound -> Stubby -> Cloudflare/Quad9 DoT
9502235  Invert WAN/LAN: eth0 (built-in) = WAN, eth1 (UGREEN) = LAN
fc89d7f  Add dual-band WiFi: 5 GHz on Panda, 2.4 GHz on Pi built-in
54aa4dc  Add Cockpit, Webmin, and isc-dhcp-server; move DHCP off Pi-hole
9b82b58  Schedule updates and Pi-hole refresh for Sunday 4 AM
9d9308c  Migrate firewall from iptables-persistent to nftables
```

---

## What the installer does now

### Phase 1 (install.sh)

- Prompts: SSIDs, WiFi password, country, subnets, Pi-hole admin password,
  optional Nighthawk MAC for DHCP reservation
- Detects UGREEN and Panda by MAC, locks interface names via .link files
- apt installs: dhcpcd5, hostapd, nftables, curl, ca-certificates, fail2ban,
  unattended-upgrades, cockpit, zram-tools
- Installs log2ram (128M) via azlux repo
- Configures zram swap (25% RAM = ~512 MB)
- Sets journald to volatile + 20M cap (prevents overflow when /var/log is a tmpfs)
- Configures timesyncd with IP-only NTP: 162.159.200.1, 216.239.35.0, 69.9.131.124
- WAN DHCP hardening on eth0: metric 100, timeout 60, reboot 30
- Writes nftables.conf, dhcpcd.conf, hostapd configs, sysctl, SSH hardening
- Saves state to /etc/freedom-pi/install.conf (including NIGHTHAWK_MAC)
- Reboots into phase 2

### Phase 2 (phase2.sh, runs once on first boot)

- Installs Stubby + Unbound
- Installs Pi-hole unattended
- Restores Teleporter backup from /boot/firmware/pihole-teleporter.tar.gz if present
- Patches pihole.toml:
  - listeningMode: LOCAL -> ALL
  - upstreams -> Unbound at 127.0.0.1#5335
  - ntp server: pool.ntp.org -> 162.159.200.1 (IP, no hostname)
  - maxDBdays: 365 -> 30
- Writes /etc/logrotate.d/pihole with copytruncate
- Installs Webmin (port 10000)
- Installs isc-dhcp-server, writes dhcpd.conf for all three subnets
- Writes Nighthawk static DHCP reservation (LAN_SUBNET.2) if MAC was provided
- Schedules weekly pihole -up at Sunday 04:00
- Self-destructs

---

## Key files

```
installer/install.sh              phase 1 entry point
installer/phase2/phase2.sh        phase 2 (runs on first boot)
installer/lib/common.sh           shared helpers (prompts, MAC detection)
installer/configs/
  nftables.conf                   firewall (v4 + v6)
  dhcpcd.conf.append              static IPs + WAN DHCP hardening
  10-eth1.link                    pins UGREEN to eth1 by MAC
  20-wlan0.link                   pins Panda to wlan0 by MAC
  hostapd-panda.conf              5 GHz AP config
  hostapd-2g.conf                 2.4 GHz AP config
  stubby.yml                      DoT config
  unbound-pihole.conf             Unbound forwarder config
FAILOVER.md                       cable-swap procedures (outcomes A/B/C)
installer/README.md               full installer docs + Known Issues Mitigated
README.md                         project overview (now accurate for this fork)
```

---

## Known issues baked in as fixes

All of these were discovered on a Pi 3 A+ and pre-fixed in the installer:

1. **Journal overflow with log2ram** - Storage=volatile in journald.conf.d/router.conf
   moves journal to /run instead of /var/log, so the 20M cap actually works.

2. **timesyncd DNS race** - NTP servers configured as IPs only. Adding
   After=network-online.target breaks timesyncd silently (conflicts with
   Before=sysinit.target). IP-only is the correct fix.

3. **Pi-hole FTL NTP DNS race** - Pi-hole v6 has its own NTP client separate
   from timesyncd. Patched to use 162.159.200.1 instead of pool.ntp.org.

4. **logrotate silently fails on Pi-hole** - FTL holds log file open by fd.
   copytruncate in /etc/logrotate.d/pihole is required.

5. **maxDBdays 365** - Bloats FTL database to multiple GB over time on a busy
   network. Set to 30 days.

---

## What's NOT done yet (deferred)

- **Monitoring/alerts** - disk usage, WAN watchdog. User wants to handle this
  with Netdata + Healthchecks.io in a future session. No webhook infrastructure
  added yet.

- **Tailscale exit node** - Pi as Tailscale exit node for remote Pi-hole access.
  Planned but not started. Will need nftables rules for the tunnel interface.

- **Homarr dashboard, Healthchecks.io + Discord, Netdata** - all queued for
  future sessions after the Pi is live and stable.

- **Pi 3 A+ Pi-hole migration** - existing Pi 3 A+ runs Pi-hole. Teleporter
  backup/restore is already coded into phase 2 (checks for
  /boot/firmware/pihole-teleporter.tar.gz). User will add blocklists manually
  rather than restoring from backup.

---

## What's left before the first test run

Physical (do before test night):
1. Flash Pi OS Lite 64-bit to NVMe using Pi Imager
   - Set hostname, enable SSH, create user in Imager before flashing
2. Assemble Pi: M.2 HAT, NVMe, UGREEN in USB 3.0 port, Panda in USB, 27W PSU
3. Factory reset Nighthawk, configure on a different subnet (e.g. 192.168.20.x)
4. Test Nighthawk in bypass mode: plug direct to XB8, confirm internet works, plug back
5. Get Nighthawk MAC address (sticker on bottom)
6. Know XB8 admin password (sticker or your set password) for bridge mode

Running installer:
7. Boot Pi, SSH in, clone repo or scp installer folder
8. sudo installer/install.sh
9. Answer all prompts (have Nighthawk MAC ready)

Test night procedure: see FAILOVER.md

---

## XB8 bridge mode notes

- When XB8 is in bridge mode, 10.0.0.1 admin page is NOT reachable from the LAN.
  The LAN ports are physically alive but DHCP is off so a connected laptop gets
  no 10.x.x.x IP.
- To undo bridge mode: Xfinity app (try first), call Comcast, or factory reset XB8.
- Factory reset restores XB8 to full router mode, WiFi comes back, 10.0.0.1 works.
  Loses custom XB8 settings (minimal on a rented gateway).

---

## How to start the next session

Option 1 - Same machine, same directory (memory auto-loads):
  cd /home/i4i/DIY-freedom-pi-router-own
  claude

Option 2 - Fresh machine or new session with full context:
  Paste the contents of this file at the start of the conversation, then say
  what you want to work on next. The GitHub repo has all the code:
  https://github.com/NI-4-NI/DIY-freedom-pi-router-own
