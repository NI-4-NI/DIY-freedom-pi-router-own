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
          -> Nighthawk WAN port
              Nighthawk runs downstairs WiFi + its own subnet
```

---

## Outcome B: Pi is down, Nighthawk takes over (one cable swap)

Use this if the Pi won't boot, won't route, or you need internet now and can debug later.
The XB8 stays in bridge mode. No config changes needed on the Nighthawk.

**Steps:**

1. Unplug the cable from XB8 LAN port going to Pi eth0.
2. Unplug the cable from Pi eth1 going to Nighthawk WAN.
3. Plug a cable directly from XB8 LAN port to Nighthawk WAN port.
4. Wait 60 seconds. Nighthawk pulls a public IP from Comcast directly.
5. Reconnect devices to Nighthawk's WiFi.

You now have internet. No Pi-hole, no upstairs Pi WiFi, but the house is online.
Debug the Pi tomorrow.

```
Coax from wall
  -> XB8 (bridge mode, still)
      -> Nighthawk WAN port  <-- direct, no Pi in the middle
          Nighthawk runs all WiFi + routing
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

## Nighthawk IP reservation

If you provided the Nighthawk MAC during install, it always gets the same IP
from the Pi's DHCP server: `<LAN_SUBNET>.2` (e.g. `192.168.1.2`).

This means if you ever add nftables rules that reference the downstream router,
the IP will never change even after a reboot or lease renewal.

---

## Pre-test checklist (do this before the test night)

- [ ] Factory reset Nighthawk, configure LAN subnet as something different from
      the Pi's subnets (e.g. 192.168.20.x vs Pi's 192.168.1.x)
- [ ] Test Nighthawk in bypass mode: plug it directly into XB8, confirm internet
      works, plug it back into normal position. This proves outcome B works before
      you need it.
- [ ] Write down the XB8 admin password (on the sticker or what you set).
      You need it for outcome C.
- [ ] Have a phone on cellular as backup internet during the test.
- [ ] Know where all three cables are before you start:
      - Coax to XB8 (don't touch this one)
      - XB8 LAN -> Pi eth0 (WAN cable)
      - Pi eth1 -> Nighthawk WAN (LAN cable)

---

## Test night order of operations

1. Connect cables in outcome A layout.
2. Enable bridge mode on XB8 via 10.0.0.1 (or call Comcast).
3. Reboot: XB8 first, then Pi, then Nighthawk. Wait 2-3 minutes.
4. Connect a laptop to Pi's WiFi. Confirm internet + check Pi-hole is seeing queries.
5. Connect a laptop to Nighthawk's WiFi. Confirm internet.
6. Dry-run outcome B: swap to direct cable, confirm Nighthawk works standalone.
   Swap back to cascade.

If step 4/5 is broken and you can't figure it out in 30 minutes, do outcome B
and sleep. The house has internet.
