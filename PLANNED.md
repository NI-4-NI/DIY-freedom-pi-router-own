# Planned Features

Features queued for future sessions after the Pi is live and stable.

---

## Monitoring and Alerts

- **Netdata** — Real-time system monitoring (CPU, RAM, disk, network throughput, Pi-hole stats). Local dashboard and optional cloud metrics.
- **Healthchecks.io + Discord** — Dead-man switch alerts for:
  - WAN watchdog (ping check, alert if Pi goes offline)
  - Disk usage >80% (NVMe filling up)
  - Pi-hole FTL service down

## Remote Access

- **Tailscale exit node** — Pi as Tailscale exit node for remote Pi-hole access from anywhere. Requires additional nftables rules for the `tailscale0` tunnel interface (masquerade + forwarding rules not yet written).

## Dashboards

- **Homarr** — Home dashboard aggregating Pi-hole, Cockpit, Webmin, and future services into one page.

## Hardware Add-ons

- **2-inch LCD display + rotary encoder** — Attach a small display to the Pi (GPIO or I2C) showing local status: Pi-hole query graph, CPU temp, WAN up/down, memory usage. Rotary encoder cycles between views. Implementation details TBD (likely luma.lcd or similar Python library with custom scripts). Physical wiring plan not started.

