# Pre-Test Checklist and Test Night Procedure

Do all of section 1 and 2 before test night. Section 3 is the test night itself.

---

## 1. Set up the Cudy AX3000 (OpenWrt)

OpenWrt defaults to `192.168.1.x` for its LAN after flash. The Pi installer also defaults to `192.168.1.x` for its LAN. Both on the same subnet with the Cudy acting as the bridge between them breaks routing. Fix it before connecting anything.

1. Flash the Cudy AX3000 to OpenWrt using the Cudy stock web UI (Firmware Upgrade page). Download the OpenWrt image for the Cudy AX3000 from the OpenWrt table of hardware first.
2. After flash, the Cudy comes up at `192.168.1.1`. Connect a laptop to a Cudy LAN port and open `http://192.168.1.1`.
3. **Change the Cudy's LAN subnet** so it does not conflict with the Pi's subnets:
   - Network -> Interfaces -> LAN -> Edit
   - Change the IPv4 address from `192.168.1.1` to `192.168.20.1`
   - Save and apply. Cudy reboots. New admin address is `http://192.168.20.1`.
4. **Get the Cudy's WAN MAC address** — this is what you give the Pi installer for the DHCP reservation:
   - In OpenWrt: Network -> Interfaces -> WAN, look at the Device or Status section for the MAC.
   - Write it down. Do not use the sticker MAC — that is the LAN MAC, the WAN MAC may differ in OpenWrt.
5. Test the Cudy in bypass mode:
   - Plug the Cudy's WAN port directly into an XB8 LAN port.
   - Wait 60 seconds. Confirm internet works on a device connected to Cudy's WiFi.
   - Unplug. This proves Outcome B works before you need it.

---

## 2. Set up the Pi

1. Flash Raspberry Pi OS Lite (64-bit) to the NVMe using Pi Imager.
   - In Pi Imager advanced settings before writing: set hostname, enable SSH, create your user.
2. Assemble the Pi:
   - M.2 HAT + Kioxia NVMe
   - UGREEN USB ethernet adapter into a blue USB 3.0 port (this becomes eth1 / LAN)
   - Panda PAU0F USB WiFi adapter
   - Official 27W USB-C power supply
3. Boot the Pi. SSH in.
4. Clone the repo or copy the installer: `scp -r installer freedompi@<pi-ip>:~/`
5. Run the installer: `sudo ~/installer/install.sh`
6. Answer all prompts. Have the Cudy WAN MAC ready when it asks for the downstream router MAC.

---

## 3. Before test night — know your cables

Three cables matter:

- Coax from wall to XB8 — do not touch this one
- XB8 LAN port -> Pi eth0 (the WAN cable)
- Pi eth1 (UGREEN) -> Cudy AX3000 WAN port (the cascade cable)

Also have ready:

- [ ] XB8 admin password (on the gateway sticker or what you set). Needed for bridge mode.
- [ ] Phone on cellular as backup internet while testing.

---

## 4. Test night order of operations

1. Connect all cables in the Outcome A cascade layout (see FAILOVER.md).
2. Enable bridge mode on XB8 via `http://10.0.0.1` (or call Comcast to toggle it remotely).
3. Reboot in order: XB8 first, then Pi, then Cudy. Wait 2-3 minutes.
4. Connect a laptop to the Pi's WiFi. Confirm internet works. Open the Pi-hole admin and confirm it is seeing queries.
5. Connect a laptop to the Cudy's WiFi. Confirm internet works.
6. Dry-run Outcome B: unplug the Pi eth1 -> Cudy WAN cable, plug a cable directly from XB8 to Cudy WAN. Confirm internet still works. Swap back to cascade. This proves the fallback without an emergency.

If step 4 or 5 is broken and you cannot figure it out in 30 minutes: execute Outcome B from FAILOVER.md and sleep. The house has internet, debug the Pi tomorrow.

---

See [FAILOVER.md](FAILOVER.md) for the three recovery outcomes and the Cudy IP reservation details.
