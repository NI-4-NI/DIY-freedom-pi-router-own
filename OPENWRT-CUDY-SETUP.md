# OpenWrt Setup on the Cudy WR3000 v1

The downstream router in this project is a Cudy WR3000 v1 flashed with OpenWrt. This is a from-zero walkthrough for a brand new Cudy, ending with the device sitting on `192.168.20.1` ready to be plugged into the Pi 5's LAN port.

Do this with the Cudy disconnected from the modem. The whole thing happens over a single LAN-port ethernet cable to a laptop.

---

## Before you start

### Verify the hardware revision

Check the serial number sticker on the bottom of the Cudy.

- SN prefix `2506` (or any value below `2543`): standard WR3000 v1. Use the firmware below.
- SN prefix `2543` or higher: "New Flash" revision. The files below will brick it. Get the matching new-flash firmware from Cudy support before going further.

### Download both files

You need two firmware images. They do different things and are not interchangeable.

**File A** (Cudy-signed intermediate OpenWrt image):
- Source: Cudy's Google Drive
- Folder: `WR3000 v1 without recovery TFTP`
- File you want: `openwrt-mediatek-filogic-cudy_wr3000-v1-squashfs-sysupgrade.bin` (the `.bin`, not the `.zip`)
- Size: roughly 9 to 10 MB

**File B** (clean upstream OpenWrt):
- Source: https://firmware-selector.openwrt.org/?target=mediatek%2Ffilogic&id=cudy_wr3000-v1
- File you want: **Sysupgrade image** (NOT the Factory image, NOT a snapshot)
- Filename will look like `openwrt-25.x.x-mediatek-filogic-cudy_wr3000-v1-squashfs-sysupgrade.bin`
- Size: roughly 7 to 8 MB

Save both somewhere obvious (Downloads is fine). Do not rename them, the names tell you what they are.

### What you need

- A laptop with an ethernet port (or a USB-to-ethernet adapter)
- One short ethernet cable
- Cudy WR3000 v1 powered on, nothing in the WAN port

---

## Stage 1: Flash the Cudy-signed intermediate (File A)

Cudy's stock firmware will refuse to flash a direct upstream OpenWrt image. The intermediate is signed by Cudy and accepted by stock firmware, and it leaves you on a stripped OpenWrt LuCI from which you can flash the real thing.

1. Plug the laptop into any Cudy LAN port. Wait for a DHCP lease.
2. Browse to `http://192.168.10.1`. This is stock Cudy admin.
3. Run through the setup wizard. Operation Mode: Wireless Router. WAN mode: DHCP. You can ignore the "No broadband access signal detected" warning since nothing is plugged into WAN. Skip or accept the defaults the rest of the way through, this config gets wiped in a minute anyway.
4. Once at the admin home page, find **Firmware Upgrade** (under Advanced or System depending on stock firmware version).
5. Click Browse, pick **File A**, upload, confirm the flash.
6. Wait. The Cudy reboots into intermediate OpenWrt. This takes 2 to 4 minutes. Browser will say "flashing..." forever, that's fine. The router is what matters, not the browser.
7. The intermediate comes up at `http://192.168.1.1` (OpenWrt default, not Cudy stock's `192.168.10.1`).
8. Release/renew the laptop's DHCP lease (toggle ethernet off/on is fastest). Confirm you have a `192.168.1.x` address.
9. Browse to `http://192.168.1.1`. You should see OpenWrt LuCI login.

---

## Stage 2: Flash clean upstream OpenWrt (File B)

The intermediate is a working OpenWrt, but it ships with extra Cudy-specific defaults you don't want carried into your config. Flashing File B with settings reset gives you a clean baseline.

1. Log in to LuCI at `http://192.168.1.1`. Default credentials: username `root`, blank password.
2. Go to **System → Backup / Flash Firmware**.
3. Under "Flash new firmware image":
   - **Uncheck "Keep settings"**. This is the most important checkbox in the whole procedure. If you leave it checked, the new image inherits the intermediate's quirks and you may end up with a half-broken config.
   - Click Browse, select **File B**, click Flash image.
4. LuCI shows a checksum confirmation page. Verify the checksum matches what the firmware-selector page showed. Click Proceed.
5. Wait through the reboot. Same 2 to 4 minutes.
6. Renew DHCP again. Browse to `http://192.168.1.1`. Clean OpenWrt.

---

## Initial OpenWrt config

You're now running clean OpenWrt at `192.168.1.1`. Lock it down and move it to the project subnet before plugging it into anything.

### Set the root password (do this first)

Default LuCI has no root password. Anyone on the LAN can log in as root until you fix this.

1. LuCI → **System → Administration**.
2. Type a strong password into both fields. Save & Apply.
3. SSH access (port 22, dropbear) now also uses this password.

### Change the LAN IP to 192.168.20.1

1. LuCI → **Network → Interfaces → LAN → Edit**.
2. Confirm Protocol is **Static address**.
3. **IPv4 address**: `192.168.20.1`
4. **IPv4 netmask**: `255.255.255.0`
5. **IPv4 gateway**: leave blank (this device is a router, not a client)
6. **IPv4 broadcast**: leave blank or set `192.168.20.255`, OpenWrt fills it automatically.
7. Click **Save**, then **Save & Apply** at the bottom of the Interfaces page.
8. Your browser connection will drop mid-apply. This is expected, the router moved.
9. Renew the laptop's DHCP. You should get a new lease in `192.168.20.x`.
10. Browse to `http://192.168.20.1`. Log back in.

### Configure the DHCP server

Still in the LAN interface, click the **DHCP Server** tab.

- **Ignore interface**: unchecked (DHCP enabled)
- **Start**: `50` (so the pool starts at `192.168.20.50`)
- **Limit**: `150` (pool runs through `192.168.20.199`)
- **Lease time**: `24h`

This leaves `192.168.20.2` through `192.168.20.49` available for static reservations later.

Save & Apply.

### Confirm WAN is set to DHCP client

1. **Network → Interfaces → WAN → Edit**.
2. Protocol: **DHCP client** (default after a clean flash).
3. Save & Apply if you changed anything.

Once the Cudy gets plugged into the Pi 5's LAN port, the Pi's DHCP server will hand it an IP on `192.168.10.x`. If the Pi installer's DHCP reservation step was given the Cudy's WAN MAC, that IP will be `192.168.10.2` consistently.

### Get the WAN MAC for the Pi installer

This is the value the Pi installer asks for when it sets up the DHCP reservation.

1. **Network → Interfaces → WAN**.
2. Look at the Status block or click the device. The MAC will be in the form `aa:bb:cc:dd:ee:ff`.
3. Write it down. Do NOT use the MAC printed on the Cudy's sticker, that's typically the LAN MAC and the WAN MAC differs.

### Wireless

1. **Network → Wireless**. You'll see two radios. The OpenWrt overview labels each one with its band (2.4 GHz / 5 GHz) next to the radio name — check that before assigning SSIDs.

   On MT7981 boards the band assignment is sometimes reversed from what documentation suggests: `radio0` may be 2.4 GHz and `radio1` may be 5 GHz. The procedure works either way — just assign the `-5G` and `-2G` SSID suffixes to whichever radio the UI shows as 5 GHz and 2.4 GHz respectively.

2. For each radio:
   - Click **Edit** on the default disabled SSID.
   - Tab: Device Configuration → confirm channel set to **auto** (or pick manually if you want).
   - Tab: Interface Configuration → set the SSID. Suggest distinguishing the two: e.g. `myssid-5G` and `myssid-2G`.
   - Tab: Wireless Security → Encryption: **WPA2-PSK/WPA3-PSK Mixed Mode**. Set a strong password.
   - Save.
3. Back on the Wireless overview page, click **Enable** on each radio.
4. Save & Apply.

If you only see one radio, the second one is probably disabled at the hardware level by default. Click **Add** on the missing band or scroll for an "Enable" link.

### Hostname and timezone

LuCI → **System → System** → General Settings tab:

- **Hostname**: something other than `OpenWrt`. Suggest `cudy-downstairs` or similar.
- **Timezone**: set your local timezone from the dropdown.

Save & Apply.

### Package updates (optional, requires WAN connectivity)

Defer this until after the Cudy is plugged into the Pi 5 and has internet. Then:

1. SSH in: `ssh root@192.168.20.1`
2. `opkg update`
3. `opkg list-upgradable`
4. Selectively upgrade packages with `opkg upgrade <name>`. Don't blindly upgrade everything, OpenWrt's overlay storage is small and a full upgrade can fill it.

---

## Maintenance and future updates

### Backing up your config

Before any firmware change, save your current config:

- LuCI → **System → Backup / Flash Firmware → Generate archive**. This downloads a `.tar.gz` of all your `/etc/config/` files: network, wireless, DHCP leases, firewall.
- Keep one copy somewhere off the router. If you flash with settings reset, this is what you restore from.

### Package-level updates (routine)

Run after the Cudy has been live for a while, over SSH:

```bash
opkg update
opkg list-upgradable
opkg upgrade <package-name>   # upgrade specific packages, not everything at once
```

Never run `opkg upgrade` with no arguments — it can overwrite kernel modules and break the system. Upgrade selectively: `luci`, `dropbear`, `openssl` packages are generally safe. Kernel and driver packages are risky without a matching kernel version.

### OpenWrt version upgrades (major or minor releases)

When a new OpenWrt release is published for the WR3000 v1:

1. Download the new **sysupgrade** image from the firmware selector (same URL as File B in the flash procedure).
2. Back up your config (see above).
3. LuCI → **System → Backup / Flash Firmware → Flash new firmware image**.
   - **Minor version upgrade** (e.g. 24.x → 24.x+1): "Keep settings" is usually safe if you haven't done anything exotic. Flash, reboot, verify everything works.
   - **Major version upgrade** (e.g. 24.x → 25.x): flash with **"Keep settings" unchecked**. Config files from a major version can carry stale values that cause subtle breakage. Reconfigure from scratch after reboot.
4. After a settings-reset flash, redo in order: root password, LAN IP (192.168.20.1), DHCP pool, WAN mode, both WiFi radios, hostname, timezone.

### Static DHCP leases

If you've added static leases (Network → DHCP and DNS → Static Leases), they're included in the config backup archive. After a settings-reset upgrade, re-import or re-add them manually.

---

## Verification before plugging into the Pi

Quick sanity checks before this gets cascaded:

- [ ] LuCI reachable at `http://192.168.20.1`
- [ ] Root password set
- [ ] DHCP handing out leases (test by reconnecting the laptop, confirm new lease in `192.168.20.x`)
- [ ] Both Wi-Fi SSIDs broadcasting (check from a phone)
- [ ] WAN MAC recorded for the Pi installer
- [ ] Hostname and timezone set
- [ ] `192.168.20.1` not reachable via the WAN port (firewall default, but worth confirming once the Pi is upstream)

---

## After this is done

Plug the cable from the Pi 5's LAN port (UGREEN USB ethernet, `eth1`) into the Cudy's **WAN** port. Within 30 seconds the Cudy's WAN interface pulls a `192.168.10.x` lease from the Pi. Devices on the Cudy's network route through the Pi for internet — that's just NAT, unavoidable by design.

Pi-hole is separate. It only filters DNS for devices that are explicitly pointed at it. Cudy LAN devices use whatever DNS the Cudy's DHCP assigns them (by default the Cudy itself, which forwards upstream, bypassing Pi-hole). To opt a specific device into Pi-hole, manually set that device's DNS server to `192.168.10.1` (the Pi's LAN IP). Everything else is unfiltered.

See [FAILOVER.md](FAILOVER.md) for what to do if the Pi dies and the Cudy needs to take over directly off the XB8.
