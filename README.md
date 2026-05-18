<p align="center">
  <img src="assets/swiz-logo-horizontal.png" alt="Swiz Security" width="560" />
</p>

# Raspberry Pi 5 Router with Pi-hole

Turn a Pi 5 into your actual home router. Built-in ethernet on the WAN side, USB ethernet on the LAN side, USB WiFi broadcasting your network. Pi-hole, Unbound, and Stubby run on top for ad blocking and encrypted DNS.

One command sets the whole thing up on a fresh Raspberry Pi OS Lite install.

## Don't wanna read? Run this

On a fresh Raspberry Pi OS Lite install with SSH on and the UGREEN plugged in:

```bash
bash <(curl -sSL https://protocol.swizsecurity.com/diy-pi-router/bootstrap.sh)
```

That pulls the installer from this repo and runs it. Two phases, one reboot in the middle, about 10 minutes total. Answer the prompts (SSID, passwords, subnets) and it's off.

Installer docs, what each phase does, and how to recover if something breaks: [installer/README.md](installer/README.md).

## Hardware

### What you need

- Raspberry Pi 5 (2 GB RAM minimum, 4 GB or 8 GB recommended)
- NVMe SSD via the official Pi M.2 HAT, **or** a microSD card (32 GB+, class 10 or A2)
- Official 27W USB-C power supply (cheap knockoffs make the Pi throttle)
- Two ethernet cables, cat5e or better
- One USB ethernet adapter for the LAN side (connects to your switch or downstream router)
- Keyboard and monitor for first boot, OR an ethernet connection to your existing network

### What I actually run

- **WAN (internet side):** Pi 5 built-in 1 GbE ethernet port. Goes straight to the modem. Becomes `eth0`.
- **LAN (home side):** UGREEN 1 GbE USB-A ethernet adapter. About $15. Plugs into a blue USB 3.0 port, connects to your switch or downstream router. Becomes `eth1`.
- **WiFi broadcast:** Panda PAU0F AXE3000 USB 3.0, MediaTek MT7921AU (mt76 driver). About $30. Runs 5 GHz AP as `wlan0`. Pi built-in WiFi runs 2.4 GHz AP as `wlan_onboard`.
- **Boot drive:** Official Raspberry Pi M.2 HAT with Kioxia 128 GB NVMe. No microSD involved.
- **Power:** Official 27W USB-C supply.

Note: this fork inverts the WAN/LAN assignment from the upstream repo. Here the built-in port is WAN and the USB adapter is LAN. Both are 1 GbE so there is no speed difference, this is just a wiring preference.

### Skip these

- **TP-Link UE306 or anything with an RTL8153 chip.** Looks great at $10, terrible Linux driver, caps around 300 Mbps because it negotiates half duplex.
- **WiFi 6 USB sticks under $30.** Most are receive-only, no AP mode. hostapd won't work.
- **Realtek RTL8812AU WiFi sticks.** Out-of-tree driver that breaks on every kernel update.
- **Cheap cat5 cables.** Old cat5 forces gigabit links into half duplex. Use cat5e or cat6.

## What the installer does

### Phase 1 (about 5 min, you answer prompts)

1. Asks for SSIDs, WiFi password, country, subnets, Pi-hole admin password, optional downstream router MAC for DHCP reservation
2. Finds your USB ethernet and WiFi radios by MAC, confirms which is which
3. Installs packages (dhcpcd5, hostapd, nftables, curl, fail2ban, unattended-upgrades, cockpit, zram-tools)
4. Kills NetworkManager, switches to dhcpcd
5. Locks interface names by MAC: `eth0` built-in WAN, `eth1` UGREEN LAN, `wlan0` Panda 5 GHz, `wlan_onboard` built-in 2.4 GHz
6. Writes dhcpcd static IPs with hardened WAN DHCP timing, sysctl tuning, nftables v4+v6 ruleset, hostapd configs
7. Hardens the host: SSH key-only, root login off, `MaxAuthTries 3`, fail2ban, unattended-upgrades, Cockpit on port 9090
8. Installs log2ram (128 MB), configures zram swap (25% RAM), sets journal to volatile with 20 MB cap
9. Configures NTP with IP addresses only (no hostnames, avoids DNS race on boot)
10. Stages the phase 2 oneshot and reboots

### Phase 2 (about 5 min, hands off)

Runs automatically on first boot after phase 1.

1. Waits for wlan0 and eth0 WAN DHCP to come up before downloading anything
2. Installs Stubby (DNS-over-TLS) and Unbound (caching forwarder)
3. Installs Pi-hole unattended, sets admin password
4. Patches `pihole.toml`: listeningMode ALL, DNS upstream to Unbound, FTL NTP to IP address, DB retention 30 days
5. Writes `/etc/logrotate.d/pihole` with copytruncate
6. Installs Webmin (port 10000), isc-dhcp-server, adds downstream router DHCP reservation if MAC was provided
7. Schedules weekly `pihole -up` at Sunday 04:00
8. Self-destructs its own systemd unit

Logs land in `/var/log/freedom-pi-phase2.log`. Full breakdown in [installer/README.md](installer/README.md).

## Plug it inline when you're done

The installer configures the Pi to BE a router, but doesn't rewire your house. Do that part once phase 2 is finished:

1. Plug the ISP modem (or modem in bridge mode) into the Pi's **built-in ethernet port** (`eth0`, WAN side).
2. Plug the Pi's **UGREEN USB ethernet adapter** (`eth1`, LAN side) into your switch or downstream router.
3. Each device on the LAN grabs a new IP from the Pi within ~10 seconds. If one is stubborn, unplug and replug its cable.

See [FAILOVER.md](../FAILOVER.md) for the full cascade setup, bypass procedure, and pre-test checklist if you're running the Pi behind a modem in bridge mode with a downstream router.

Verify you're actually inline:

```bash
ip -br addr | grep -E 'eth|wlan'
```

- `eth0` should have the ISP-assigned public IP (or modem-assigned IP in bridge mode)
- `eth1` should only have your static LAN gateway IP (e.g. `192.168.1.1/24`), no ISP IP on it

If `eth1` has two IPs, a modem-to-switch bypass cable is still plugged in somewhere. Find it and unplug it.

## Client-side gotchas

Nothing the installer can fix on your other devices. Heads up for when you're troubleshooting.

- **iCloud Private Relay hides DNS failures on iPhones.** If Pi-hole is broken, Safari still loads because Apple tunnels its own DNS. Phone looks fine, Pi-hole sees zero queries. Turn Private Relay off in Settings to confirm.
- **macOS caches manual DNS.** If any interface has manual DNS set in System Settings, it overrides DHCP. Clear with `sudo networksetup -setdnsservers "Interface Name" "Empty"`. Check with `scutil --dns | grep -A 3 "resolver #1"`, should point at your LAN gateway, not `1.1.1.1`.
- **Windows hangs onto old DHCP leases.** After going inline, run `ipconfig /release` then `ipconfig /renew` in an admin PowerShell.

## Security out of the box

Out of the box the installer locks the Pi down so you're not exposing a router to the internet with factory defaults.

### Firewall

- v4 INPUT defaults to DROP. LAN (`eth1`) and WiFi (`wlan0`, `wlan_onboard`) get the usual ports (SSH, DNS, DHCP, HTTP, HTTPS, ICMP). WAN (`eth0`) accepts nothing unsolicited, only return traffic for connections your LAN started.
- v6 INPUT defaults to DROP too. That matters because IPv6 has no NAT, so every device behind your modem typically gets its own public address. Without a v6 firewall, the Pi's SSH and Pi-hole admin would be reachable from the whole v6 internet.
- LAN and WiFi subnets aren't bridged. A compromised WiFi device can't touch your wired machines without going back through the Pi.

### Host

- SSH: key-only, root logins off, `MaxAuthTries 3`. If the installing user has no `authorized_keys` file the installer leaves password auth alone, so you can't lock yourself out.
- `fail2ban` is running with the stock sshd jail.
- `unattended-upgrades` is running. Security patches apply on their own.
- Kernel: `rp_filter` anti-spoof, SYN cookies on, source-routed packets dropped, ICMP redirects ignored, martians logged to dmesg.

### Stuff to do yourself

- If you picked a weak Pi-hole admin password, change it.
- The default leaves v6 forwarding off, so LAN clients don't get public v6 addresses. If you want your clients on v6, you have to set up downstream prefix delegation yourself.

To verify: from your phone on cellular (WiFi off), try `ssh <your public WAN IP>` and `curl http://[<your Pi's public v6 addr>]/admin/`. Both should time out.

## What this unlocks

Every packet from every device on your network now flows through Pi-hole. From here:

- Pump up the blocklists in the Pi-hole admin
- Turn on DNS over HTTPS upstream so your ISP can't read your queries
- `tcpdump` any specific device from the Pi
- Add Suricata or Snort if you want IDS/IPS
- Plug IoT junk into the wired LAN and actually see what it phones home to
