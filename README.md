# Network Monitor

A fully native macOS app that shows every network connection leaving your Mac in real time — including background traffic from system daemons — with the originating process, destination, port, protocol type, and timestamp. Activity Monitor-style UI built in SwiftUI.

## How it works

The app reads flow data from `NetworkStatistics.framework`, the private system framework that powers `nettop` and Activity Monitor's network view. The kernel reports every TCP and UDP flow on the machine (all users, all processes) with process attribution — no root, no kernel extension, no system extension approval required.

Because it's a **passive observer** (it reads kernel statistics rather than sitting inline in the network stack), it cannot block traffic, and hostnames come from best-effort reverse DNS rather than inspecting the actual DNS/TLS traffic. See the comparison below.

- `Sources/NetworkMonitor/NetworkStatistics.swift` — `dlopen`/`dlsym` bindings for the private framework
- `Sources/NetworkMonitor/FlowMonitor.swift` — turns NStat callbacks into typed flow events
- `Sources/NetworkMonitor/FlowStore.swift` — main-actor model; coalesces event bursts before hitting SwiftUI
- `Sources/NetworkMonitor/ContentView.swift` — the table UI (search, pause, filters)
- `probe/probe.swift` — standalone CLI used to verify the private API's behavior on this macOS version

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
| Hostnames | Reverse DNS, best effort (CDN IPs often show as e.g. `ec2-….amazonaws.com`) | True domain from DNS/TLS handshake inspection |
| History | In-memory, capped at 5,000 flows, gone on quit | Persistent history (up to a year) |
| Traffic totals/charts | Per-flow bytes only | Rich charts, map view |
| Install friction | None — no extension, no approval | System extension + filter approval |
| Privacy/trust | 100% your code, fully local | Closed source (reputable vendor) |
| Future-proofing | Private API, could break in a macOS update | Public, supported API |
| Price | Free | Free to monitor; subscription to block |

What this app offers instead: zero dependencies, fully local, a few hundred lines of Swift you own and can extend however you like — and nothing runs inline with your network traffic.

## Known limitations

- **No blocking** — this is a monitor, not a firewall.
- **Hostname accuracy** — reverse DNS can't see the domain inside a TLS connection; an IP behind a CDN resolves to the CDN's name (or nothing), not the site you connected to.
- **Flow-level, not request-level** — one TCP connection or UDP socket = one row. Individual HTTP requests inside a kept-alive HTTPS connection are not visible (that would require TLS interception). DNS queries made on a process's behalf by `mDNSResponder` are attributed to `mDNSResponder`.
- **Private API** — `NetworkStatistics.framework` is unsupported by Apple and could change in a future macOS release. The probe CLI exists to re-verify quickly.
