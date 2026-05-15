# freedom-pi installer

Automated version of the big README. Takes a fresh Raspberry Pi OS Lite install and turns it into a working router with Pi-hole, WiFi AP, and firewall. Two phases, one reboot in the middle, rest is hands off.

## What you need

- Raspberry Pi 5 (any RAM)
- Fresh Raspberry Pi OS Lite (64-bit) with SSH on and a user set up via the Pi Imager
- OS drive: microSD **or** NVMe via the official Pi M.2 HAT (both work; all paths use `/boot/firmware/` which Raspberry Pi OS mounts the same way regardless of boot device)
- UGREEN USB 1 GbE ethernet adapter plugged into a USB 3.0 port (this becomes the LAN port, eth1)
- Built-in ethernet port (eth0) connected to your modem for WAN
- Panda PAU0F AXE3000 USB WiFi (or keep the Pi built-in, installer handles both)
- Internet on the Pi during install (WAN cable to your modem plugged into the built-in ethernet port)

## Run it

On your Mac:

```bash
scp -r installer freedompi@<pi-ip>:~/
ssh freedompi@<pi-ip>
```

On the Pi:

```bash
sudo ~/installer/install.sh
```

Follow the prompts. Defaults work for most setups.

## If your SSH drops, use tmux

Phase 1 kills NetworkManager partway through, which can blip your SSH session. If you're SSH'd in over WiFi, it drops and never comes back until after the Pi reboots. The install dies with it.

Wrap the install in tmux so it keeps running even if your SSH dies:

```bash
sudo apt install -y tmux          # if not already installed
tmux new -s inst                  # new session called "inst"
sudo ~/installer/install.sh       # run inside tmux
```

If the SSH session drops, reconnect and reattach:

```bash
ssh freedompi@<pi-ip>
tmux attach -t inst
```

You're back exactly where you left off, prompts and all.

Other useful bits:

- `Ctrl-b d` detaches from the session without killing it (so you can SSH out and come back later)
- `tmux ls` lists all sessions
- `tmux kill-session -t inst` cleans up when you're done

If you SSH in over a wired path (UGREEN plugged into a LAN port upstream, DHCP'd IP in the 192.168.x range), tmux is less critical because eth1 keeps its DHCP lease across the NetworkManager kill. Over WiFi, tmux is your safety net.

## What it does

### Phase 1 (about 5 min, you answer prompts)

1. Asks for SSID, WiFi password, country, subnets, Pi-hole admin password, optional downstream router MAC for DHCP reservation
2. Finds your USB ethernet and WiFi radios by MAC, confirms which is which
3. `apt install` the packages (dhcpcd5, hostapd, nftables, curl, fail2ban, unattended-upgrades, cockpit, zram-tools)
4. Kills NetworkManager, turns on dhcpcd
5. Writes `.link` files to lock interface names by MAC (`eth0`=built-in WAN, `eth1`=UGREEN LAN, `wlan0`=Panda, `wlan_onboard`=built-in WiFi)
6. Writes dhcpcd static IPs with hardened WAN DHCP timing (60s timeout, 30s retry, metric 100)
7. Writes sysctl tuning and kernel hardening (rp_filter anti-spoof, SYN cookies, no ICMP redirects, etc.)
8. Writes nftables ruleset (v4 + v6 combined) and enables the nftables service
9. Sets your WiFi country code
10. Writes hostapd config (Panda or built-in variant)
11. Host hardening: SSH drop-in (`PermitRootLogin no`, `MaxAuthTries 3`, key-only auth if `authorized_keys` exists), enables fail2ban sshd jail, enables unattended-upgrades, enables Cockpit on port 9090
12. Installs log2ram (128 MB RAM disk for `/var/log`, flushes periodically to disk)
13. Configures zram swap (25% of RAM as compressed swap, ~512 MB on a 2 GB Pi)
14. Sets systemd journal to volatile storage with 20 MB cap (avoids doubling RAM use when `/var/log` is a log2ram tmpfs)
15. Configures systemd-timesyncd with IP-only NTP servers (no hostnames, avoids DNS race on boot)
16. Stages the phase 2 oneshot
17. `update-initramfs` so the `.link` files kick in
18. Reboots

### Phase 2 (about 5 min, hands off)

Runs once automatically on first boot. Installs the DNS chain, Pi-hole, Webmin, and DHCP server, then deletes itself.

1. Waits for `wlan0` to come up at its static IP
2. Waits for `eth0` WAN DHCP lease and for DNS to actually resolve (otherwise curl fails)
3. Installs Stubby (DNS-over-TLS to Cloudflare + Quad9) and Unbound (local caching forwarder)
4. Installs Pi-hole unattended, sets admin password
5. Restores Teleporter backup if one is present at `/boot/firmware/pihole-teleporter.tar.gz`
6. Patches `/etc/pihole/pihole.toml`:
   - `listeningMode` from `LOCAL` to `ALL`
   - DNS upstream to Unbound at `127.0.0.1#5335`
   - FTL NTP server changed from `pool.ntp.org` hostname to Cloudflare IP `162.159.200.1`
   - DB retention reduced from 365 to 30 days
7. Restarts `pihole-FTL`
8. Writes `/etc/logrotate.d/pihole` with `copytruncate` (required since FTL holds the log file open)
9. Installs Webmin (port 10000)
10. Installs isc-dhcp-server, writes subnet config for LAN + both WiFi subnets, adds Nighthawk static reservation if MAC was provided
11. Schedules weekly `pihole -up` at Sunday 04:00
12. Disables and removes its own systemd unit (self-destruct)

Phase 2 logs to `/var/log/freedom-pi-phase2.log`.

## File layout

```
installer/
├── install.sh                     # phase 1 entry
├── lib/
│   └── common.sh                  # helpers (prompts, MAC detection, templating)
├── configs/
│   ├── 99-router.conf             # sysctl
│   ├── dhcpcd.conf.append         # {{LAN_GATEWAY}}, {{WIFI_GATEWAY}}
│   ├── 10-eth1.link               # {{UGREEN_MAC}}
│   ├── 20-wlan0.link              # {{PANDA_MAC}}
│   ├── 20-wlan-onboard.link       # {{BUILTIN_WIFI_MAC}}
│   ├── hostapd-panda.conf         # {{SSID}}, {{COUNTRY_CODE}}, {{WPA_PASSPHRASE}}
│   ├── hostapd-builtin.conf       # built-in Pi WiFi variant
│   ├── hostapd-default            # /etc/default/hostapd
│   ├── unblock-rfkill.conf        # hostapd systemd drop-in (fixes USB WiFi soft block)
│   ├── nftables.conf              # firewall rules v4 + v6 combined (LAN+WiFi whitelist, WAN closed)
│   ├── sshd_freedom-pi.conf       # sshd drop-in (PermitRootLogin no, MaxAuthTries 3)
│   └── 20auto-upgrades            # enables unattended-upgrades
└── phase2/
    ├── phase2.sh                  # runs on first boot
    └── freedom-pi-phase2.service  # oneshot unit, self-destructs
```

## When things break

### Phase 1 died partway

Just re-run it:

```bash
sudo ~/installer/install.sh
```

Mostly idempotent. The dhcpcd.conf append is guarded against double writes. Other configs get overwritten cleanly.

### Phase 2 didn't finish

Check the log first:

```bash
sudo cat /var/log/freedom-pi-phase2.log
sudo journalctl -u freedom-pi-phase2 --no-pager
```

If it bailed on DNS or network, wait a minute and re-run manually:

```bash
sudo systemctl reset-failed freedom-pi-phase2
sudo systemctl start freedom-pi-phase2
```

If it's still busted, run it by hand to see the live output:

```bash
sudo bash -x /etc/freedom-pi/phase2.sh
```

### You want to start over

Reflash the SD card. The installer changes too many system files for a clean uninstall.

## Stuff to know before running

- When NetworkManager gets killed, any SSH over WiFi drops. Use wired SSH (eth1 via your existing switch) so your session survives.
- Pi-hole's installer pulls a lot of stuff. Phase 2 bails if WAN isn't up, so make sure your modem cable is plugged in to `eth1` before you reboot out of phase 1.
- If your current home network already uses `192.168.1.x`, don't use that as the LAN subnet prompt or you'll get a collision. Use `192.168.10` or `192.168.50`.
- Admin password goes into `/etc/freedom-pi/install.conf` briefly between phase 1 and phase 2, escaped with `printf %q`. Phase 2 redacts it after use. File is `chmod 600 root:root`.

## Known issues mitigated

These are bugs that will bite you on a stock Pi OS install and are baked in as fixes here, so you don't hit them.

### systemd journal overflows log2ram despite MaxUse cap

**Symptom:** Journal grows past its configured cap (e.g. you set `SystemMaxUse=20M` but it keeps hitting 44 MB and filling the log2ram disk).

**Why:** The journal cap applies to `/var/log/journal/` on disk, but log2ram mounts a tmpfs over `/var/log`. The journal writes to the tmpfs and ignores the cap because it counts the tmpfs as memory, not disk.

**Fix:** `Storage=volatile` in `/etc/systemd/journald.conf.d/router.conf`. This moves the journal entirely to `/run/log/journal/` (outside log2ram's tmpfs) where the cap is correctly enforced.

### systemd-timesyncd fails to sync on boot (DNS race)

**Symptom:** Clock is wrong after boot. `systemctl status systemd-timesyncd` shows "no servers configured" or repeated "name resolution failed."

**Why:** timesyncd starts early in the boot sequence, before Pi-hole, Unbound, and Stubby are up. It tries to resolve `pool.ntp.org` or similar hostnames through the DNS chain, gets no answer, and gives up.

**Fix:** NTP configured with IP addresses only (`162.159.200.1`, `216.239.35.0`, `69.9.131.124`). No DNS lookup needed, no race.

**What not to do:** Adding `After=network-online.target` to timesyncd's unit conflicts with its original `Before=sysinit.target` and silently prevents the service from starting at all.

### Pi-hole FTL NTP has the same DNS race

**Symptom:** Pi-hole v6 logs show NTP sync failures at startup.

**Why:** Pi-hole v6 has its own built-in NTP client (separate from systemd-timesyncd) and defaults to `pool.ntp.org`, a hostname. Same race condition as above.

**Fix:** `server = "162.159.200.1"` patched into `pihole.toml` by phase 2.

### Pi-hole logrotate silently fails

**Symptom:** `/var/log/pihole/pihole.log` grows without bound. Rotation runs but the old file stays at full size.

**Why:** `pihole-FTL` keeps the log file open by file descriptor. Standard logrotate renames the file and signals the process to reopen it, but FTL doesn't respond to that signal. The new empty log gets created but FTL keeps writing to the old (renamed) file by descriptor.

**Fix:** `copytruncate` in `/etc/logrotate.d/pihole`. Instead of rename+reopen, logrotate copies the file then truncates the original in place. FTL's open descriptor keeps working, rotation works.
