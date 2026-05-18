# Failover and Recovery Procedures

Three outcomes are possible if something goes wrong. Pick the one that fits.

---

## Outcome A: Everything works (normal state)

```
Coax from wall
  -> XB8 (bridge mode, modem only)
      -> Pi eth0 (WAN)
          Pi runs router + Pi-hole + upstairs WiFi (2 bands)
      -> Pi eth1 (LAN)
          -> Cudy AX3000 WAN port
              Cudy runs downstairs WiFi + its own subnet (192.168.20.x)
```

---

## Outcome B: Pi is down, Cudy takes over (one cable swap)

Use this if the Pi won't boot, won't route, or you need internet now and can debug later.
The XB8 stays in bridge mode. No config changes needed on the Cudy.

**Steps:**

1. Unplug the cable from XB8 LAN port going to Pi eth0.
2. Unplug the cable from Pi eth1 going to Cudy WAN.
3. Plug a cable directly from XB8 LAN port to Cudy WAN port.
4. Wait 60 seconds. Cudy pulls a public IP from Comcast directly.
5. Reconnect devices to Cudy's WiFi.

You now have internet. No Pi-hole, no upstairs Pi WiFi, but the house is online.
Debug the Pi tomorrow.

```
Coax from wall
  -> XB8 (bridge mode, still)
      -> Cudy AX3000 WAN port  <-- direct, no Pi in the middle
          Cudy runs all WiFi + routing
```

---

## Outcome C: Full rollback (undo bridge mode)

Use this if you want to go back to exactly how things were before.

**Important:** In bridge mode the XB8's DHCP server is off, so plugging a
laptop into a XB8 LAN port gets you no IP and no route to 10.0.0.1. The admin
page is effectively unreachable from the LAN ports while bridge mode is active.

You have three options to undo it, in order of preference:

**Option 1 - Xfinity app on your phone (try first)**
Some accounts can toggle bridge mode from the app without touching hardware.
Check Settings -> Gateway -> At a Glance, or similar. If the toggle is there,
flip it and the XB8 restarts in router mode on its own.

**Option 2 - Call Comcast**
Ask them to disable bridge mode remotely. Tell them you want to go back to
"router mode" or "gateway mode." They can push the change from their end with
no physical access required.

**Option 3 - Factory reset the XB8 (nuclear, always works)**
Hold the reset pinhole button on the XB8 for about 10 seconds until it
restarts. It comes back up in full router mode, WiFi on, admin page at 10.0.0.1
with the credentials on the sticker. You lose any custom XB8 settings (custom
admin password, any port forwards) but on a rented Comcast gateway those are
usually minimal.

**Steps after bridge mode is off:**

1. Wait 2 minutes for the XB8 to fully restart in router mode.
2. Reconnect devices to the XB8's WiFi (it broadcasts its own SSID again).
3. Disconnect the Pi from the XB8 and power off the Pi.
4. Normal service resumes through the XB8 as if none of this happened.

---

## Cudy AX3000 IP reservation

If you provided the Cudy's WAN MAC during install, it always gets the same IP
from the Pi's DHCP server: `<LAN_SUBNET>.2` (e.g. `192.168.1.2`).

This means if you ever add nftables rules that reference the downstream router,
the IP will never change even after a reboot or lease renewal.

---

See [PRETEST.md](PRETEST.md) for the full pre-test checklist, OpenWrt setup steps, and test night procedure.
