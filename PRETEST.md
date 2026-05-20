# Pre-Test Checklist and Test Night Procedure

---

## Wiring: current state vs target state

**Right now** — XB8 is doing everything (router + modem):

```
[Coax from wall]
        |
      [XB8]   <-- router + modem combined, admin at 10.0.0.1
        |
   (XB8 LAN ports)
        |
  [all your devices]   <-- get IPs from XB8 (192.168.x.x or 10.0.0.x)
```

**Target state (Outcome A)** — XB8 becomes modem only, Pi takes over routing:

```
[Coax from wall]
        |
      [XB8]   <-- bridge mode (modem only, 10.0.0.1 unreachable)
        |
  [Pi eth0]   <-- WAN port (Pi built-in 1GbE), gets Comcast public IP
  [Pi 5]      <-- router, Pi-hole, DNS chain, firewall, upstairs WiFi
  [Pi eth1]   <-- LAN port (UGREEN USB 1GbE)
        |
  [Cudy WR3000 WAN]   <-- gets 192.168.10.2 from Pi DHCP (reserved)
  [Cudy WR3000]       <-- downstairs WiFi, own subnet 192.168.20.x

Pi also broadcasts:
  [wlan0 / Panda PAU0F]   <-- 5 GHz AP, 192.168.2.x (default, set at install)
  [wlan_onboard]          <-- 2.4 GHz AP, 192.168.3.x (default, set at install)
```

---

## Step 1: Set up the Cudy WR3000 v1

Flash and configure the Cudy ahead of time so it's ready to plug into the Pi 5's LAN port. Full procedure: [OPENWRT-CUDY-SETUP.md](OPENWRT-CUDY-SETUP.md). When done, the Cudy lives at `192.168.20.1`, has WPA2/WPA3 Wi-Fi up on both bands, and you have its WAN MAC written down for the Pi installer.

Also do the bypass test from that doc: plug Cudy WAN into XB8 LAN directly, confirm internet works from Cudy WiFi, then unplug and set the Cudy aside. This proves Outcome B works before you need it.

---

## Step 2: Set up the Pi (do this while still on normal internet)

1. Flash Raspberry Pi OS Lite (64-bit) to the NVMe using Pi Imager.
   - In Pi Imager, open settings before writing: set hostname (e.g. `freedompi`), enable SSH, create your username and password.
2. Assemble the Pi:
   - M.2 HAT + Kioxia NVMe underneath
   - UGREEN USB ethernet adapter into a **blue USB 3.0 port** (this becomes eth1, the LAN port)
   - Panda PAU0F USB WiFi adapter
   - Official 27W USB-C power supply
3. **During install, plug Pi eth0 (built-in port) into any XB8 LAN port.** The Pi needs internet to download packages. This is the same port that will later become the WAN — nothing changes physically, only the XB8 switches from router mode to bridge mode afterward.
4. Boot the Pi, wait 60 seconds, SSH in:
   ```
   ssh youruser@freedompi.local
   ```
   If `.local` doesn't work, find the Pi's IP in your router's DHCP table.
5. Get the installer onto the Pi:
   ```bash
   git clone https://github.com/NI-4-NI/DIY-freedom-pi-router-own.git
   ```
   Or copy from your Mac:
   ```bash
   scp -r installer youruser@<pi-ip>:~/
   ```
6. Run the installer (wrap in tmux so SSH drops don't kill it):
   ```bash
   sudo apt install -y tmux
   tmux new -s inst
   sudo ~/DIY-freedom-pi-router-own/installer/install.sh
   ```
7. Answer all prompts. Have the Cudy WAN MAC ready when it asks for the downstream router MAC.
8. The installer reboots the Pi halfway through. Phase 2 runs automatically on first boot and takes about 5 minutes hands-off. You can watch it with:
   ```bash
   tmux attach -t inst    # if session survived
   # or
   ssh back in and: sudo tail -f /var/log/freedom-pi-phase2.log
   ```
9. Phase 2 is done when you see `=== freedom-pi phase 2 complete ===` in the log.

---

## Step 3: Switch the XB8 to bridge mode and wire everything up

Do this after phase 2 finishes. Have your phone on cellular ready as backup internet — once bridge mode is on, all devices lose internet until the Pi cascade is up.

**Before you touch anything, confirm you have:**
- [ ] XB8 admin password (on the gateway sticker, or what you set). You need it to log in.
- [ ] Phone on cellular as backup.
- [ ] All three cables identified:
  - Coax from wall -> XB8 (do not touch)
  - XB8 LAN port -> Pi eth0 built-in (already connected from install)
  - One more ethernet cable for Pi eth1 -> Cudy WAN

**Enable bridge mode on XB8:**

Option 1 — Xfinity app on your phone: Settings -> Gateway -> At a Glance (look for bridge/IP passthrough toggle). Fastest if your account supports it.

Option 2 — XB8 web admin while still in router mode:
- Open `http://10.0.0.1` in a browser (must be on XB8 network)
- Log in with admin password
- Find "Bridge Mode" or "IP Passthrough" under Gateway settings
- Enable it. XB8 reboots into bridge mode.

Option 3 — Call Comcast and ask them to disable router mode remotely.

**After bridge mode is on:**
- `10.0.0.1` is no longer reachable — this is expected. XB8 is modem-only now.
- The cable from XB8 LAN to Pi eth0 stays exactly where it is.
- Plug the second ethernet cable from **Pi eth1 (UGREEN USB adapter)** into **Cudy WR3000 WAN port**.

**Final cable layout:**
```
[Coax]  ->  [XB8 bridge]  ->  [Pi eth0]
                                [Pi eth1 / UGREEN]  ->  [Cudy WAN]
```

---

## Step 4: First boot in cascade mode

1. Reboot in order: XB8 first (unplug/replug power), then Pi, then Cudy. Wait 2-3 minutes.
2. Connect a laptop to the Pi's WiFi (5 GHz SSID you set during install).
3. Confirm internet works. Open Pi-hole admin at `http://192.168.2.1/admin` (or your 5 GHz gateway IP) and confirm it is seeing DNS queries.
4. Connect a device to Cudy's WiFi. Confirm internet works from there too.
5. SSH into the Pi and run a quick health check:
   ```bash
   systemctl is-active hostapd pihole-FTL isc-dhcp-server fail2ban nftables
   ip -br addr | grep -E 'eth|wlan'
   ```
   - `eth0` should show the Comcast-assigned IP
   - `eth1` should show only `192.168.10.1` (your LAN gateway, no second IP)
   - `wlan0` and `wlan_onboard` should show their static IPs

---

## Step 5: Dry-run the fallback (Outcome B)

Do this before calling the test night a success.

1. Unplug the cable from Pi eth1 (UGREEN) to Cudy WAN.
2. Plug a cable directly from XB8 LAN port to Cudy WAN port.
3. Wait 60 seconds. Confirm internet works on Cudy WiFi (no Pi in the path).
4. Swap back to cascade: unplug XB8->Cudy direct, replug Pi eth1->Cudy WAN.
5. Confirm cascade is working again.

This proves that if the Pi ever dies, one cable swap gets the house back online. See [FAILOVER.md](FAILOVER.md) for the full recovery procedures.

---

If step 3 or 4 is broken and you cannot figure it out in 30 minutes: execute Outcome B from FAILOVER.md and sleep. The house has internet, debug the Pi tomorrow.
