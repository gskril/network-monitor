# Network Monitor

A fully native macOS app that shows every network connection leaving your Mac in real time — including background traffic from system daemons — with the originating process, destination, port, protocol type, and timestamp. Activity Monitor-style UI built in SwiftUI.

## How it works

The app reads flow data from `NetworkStatistics.framework`, the private system framework that powers `nettop` and Activity Monitor's network view. The kernel reports every TCP and UDP flow on the machine (all users, all processes) with process attribution — no root, no kernel extension, no system extension approval required.

Because it's a **passive observer** (it reads kernel statistics rather than sitting inline in the network stack), it cannot block traffic. Hostnames come from best-effort reverse DNS by default; with the optional BPF helper (below) it instead shows the real hostname each app requested by watching DNS responses. See the comparison below.

- `Sources/NetworkMonitor/NetworkStatistics.swift` — `dlopen`/`dlsym` bindings for the private framework
- `Sources/NetworkMonitor/FlowMonitor.swift` — turns NStat callbacks into typed flow events
- `Sources/NetworkMonitor/FlowStore.swift` — main-actor model; coalesces event bursts before hitting SwiftUI
- `Sources/NetworkMonitor/DNSSniffer.swift` / `DNSParser.swift` — optional libpcap DNS-response capture, parsed into IP→hostname mappings
- `Sources/CDNSSniff/` — minimal C shim over libpcap
- `Sources/NetworkMonitor/GeoIP.swift` — pure-Swift MaxMind/DB-IP `.mmdb` reader for offline IP geolocation
- `Sources/NetworkMonitor/ContentView.swift` — the UI: List / Domains / Map modes, search, pause, filters
- `Sources/NetworkMonitor/DomainGroupedView.swift` / `MapViews.swift` — the grouped and map views
- `probe/probe.swift` — standalone CLI used to verify the private API's behavior on this macOS version

## Views

A segmented control in the toolbar switches between three modes:

- **List** — the live flat feed, newest first.
- **Domains** — a process → registered-domain → endpoint outline (most useful for browsers, which otherwise dominate the flat list). Like Little Snitch, granularity is process + domain; neither tool can see which browser tab made a request.
- **Map** — every located server plotted on a world map, clustered by region and sized by connection count. Each flow's estimated city/country and a map pin also appear in the inspector.

## Estimated locations (optional)

The map and per-flow region need an offline IP→location database. Fetch the free DB-IP "IP to City Lite" data (CC-BY, no signup) — nothing about your connections ever leaves your Mac:

```sh
scripts/fetch-geoip.sh   # downloads ~120MB to ~/Library/Application Support/NetworkMonitor/
```

Without it the app runs fine; the Map view shows "no located connections" and the inspector omits the region section. Locations are city-level estimates from IP allocation — approximate, not exact.

## True hostnames (optional)

By default hostnames are best-effort reverse DNS, which often shows a CDN's name (`ec2-….amazonaws.com`) rather than the site an app actually contacted. To show the real requested hostname, the app can passively watch DNS responses — but that needs read access to BPF devices, which is root-only on macOS. Install the one-time helper (Wireshark's "ChmodBPF" approach: a LaunchDaemon that grants a dedicated `access_bpf` group access to `/dev/bpf*`):

```sh
sudo scripts/install-bpf-helper.sh   # one time; may require logout/login once
# relaunch the app — the status bar should read "DNS names on"
sudo scripts/uninstall-bpf-helper.sh # to revert
```

Without the helper the app runs fine and shows "DNS names off", using reverse DNS. The helper grants DNS-packet visibility to a group you're added to; it does not give the app any other privilege, and the app never runs as root.

## Build & run

```sh
swift run                  # dev run
./scripts/build-app.sh     # builds dist/NetworkMonitor.app (ad-hoc signed)
```

Requires macOS 14+. Tested on macOS 26.3 / Xcode 26.5.

## Honest comparison with Little Snitch Mini

This app was built as a personal tool. [Little Snitch Mini](https://www.obdev.at/products/littlesnitch-mini/) is a more capable product — it installs a NetworkExtension content filter that sits *inline* in the network stack (which requires Apple's paid developer entitlement), while this app passively reads kernel flow statistics. For transparency:

| | Network Monitor (this app) | Little Snitch Mini |
|---|---|---|
| Sees all processes' traffic, real-time | ✅ | ✅ |
| Process attribution | ✅ | ✅ |
| **Blocking traffic** | ❌ observation only | ✅ (with subscription, via blocklists) |
| Hostnames | Reverse DNS by default; true requested hostname with the optional BPF helper (watches DNS responses) | True domain from DNS/TLS handshake inspection |
| History | In-memory, capped at 5,000 flows, gone on quit | Persistent history (up to a year) |
| Domain grouping | ✅ process → domain → endpoint outline | ✅ |
| Map of server locations | ✅ offline, city-level estimate | ✅ city-level |
| Traffic totals/charts | Per-flow + per-domain bytes | Rich charts, map view |
| Install friction | None — no extension, no approval | System extension + filter approval |
| Privacy/trust | 100% your code, fully local | Closed source (reputable vendor) |
| Future-proofing | Private API, could break in a macOS update | Public, supported API |
| Price | Free | Free to monitor; subscription to block |

What this app offers instead: zero dependencies, fully local, a few hundred lines of Swift you own and can extend however you like — and nothing runs inline with your network traffic.

## Known limitations

- **No blocking** — this is a monitor, not a firewall.
- **Hostname accuracy** — without the BPF helper, reverse DNS can't see the domain inside a TLS connection; an IP behind a CDN resolves to the CDN's name (or nothing). The helper fixes this for hostnames resolved via the system resolver while the app is running, but can't attribute IPs that were resolved before launch or via DNS-over-HTTPS inside another app.
- **Flow-level, not request-level** — one TCP connection or UDP socket = one row. Individual HTTP requests inside a kept-alive HTTPS connection are not visible (that would require TLS interception). DNS queries made on a process's behalf by `mDNSResponder` are attributed to `mDNSResponder`.
- **Private API** — `NetworkStatistics.framework` is unsupported by Apple and could change in a future macOS release. The probe CLI exists to re-verify quickly.
