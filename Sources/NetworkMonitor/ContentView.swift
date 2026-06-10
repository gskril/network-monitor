import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: FlowStore
    @State private var searchText = ""
    @State private var selectedID: FlowRow.ID?
    @AppStorage("inspectorWidth") private var inspectorWidth = 360.0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        let visible = store.filteredRows(searchText: searchText)

        Table(visible, selection: $selectedID) {
            TableColumn("Time") { row in
                HStack(spacing: 5) {
                    Text(Self.timeFormatter.string(from: row.lastSeenAt))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(row.preexisting ? .secondary : .primary)
                    if row.count > 1 {
                        Text("×\(row.count)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(timeHelp(for: row))
            }
            .width(min: 90, ideal: 130, max: 160)

            TableColumn("Process") { row in
                HStack(spacing: 6) {
                    ProcessIcon(pid: row.pid)
                    Text(row.processName)
                        .lineLimit(1)
                    Text(String(row.pid))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 140, ideal: 190)

            TableColumn("Type") { row in
                Text(row.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(row.kind.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(row.kind.color)
            }
            .width(min: 64, ideal: 78, max: 100)

            TableColumn("Remote") { row in
                Text(row.remoteDisplay)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.remote.map { "\($0.ip):\($0.port)" } ?? "no remote endpoint")
            }
            .width(min: 180, ideal: 280)

            TableColumn("Port") { row in
                Text(row.hasRemote ? String(row.remote?.port ?? 0) : "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 56, max: 70)

            TableColumn("Iface") { row in
                Text(row.interfaceName ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 56, max: 80)

            TableColumn("State") { row in
                Text(row.stateDisplay)
                    .foregroundStyle(row.isClosed ? .tertiary : .secondary)
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Traffic") { row in
                Text(trafficText(for: row))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
        }
        .alternatingRowBackgrounds(.enabled)
        .inspector(isPresented: inspectorShown) {
            if let row = store.rows.first(where: { $0.id == selectedID }) {
                FlowDetailView(row: row)
                    .inspectorColumnWidth(min: 300, ideal: CGFloat(inspectorWidth), max: 560)
                    .background {
                        // The system doesn't persist inspector width; track it
                        // so reopening restores the user's chosen size.
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.width) { _, width in
                                if width > 0 { inspectorWidth = width }
                            }
                        }
                    }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by process, host, port, type")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.togglePause()
                } label: {
                    Label(store.isPaused ? "Resume" : "Pause",
                          systemImage: store.isPaused ? "play.fill" : "pause.fill")
                }
                .help(store.isPaused ? "Resume live capture (⌘.)" : "Pause the feed (⌘.)")

                Button {
                    store.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear all rows (⌘K)")

                Menu {
                    Toggle("Show loopback traffic", isOn: $store.showLoopback)
                    Toggle("Show listeners & unconnected sockets", isOn: $store.showUnconnected)
                    Toggle("Show flows from before launch", isOn: $store.showPreexisting)
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar(visibleCount: visible.count)
        }
        .navigationTitle("Network Monitor")
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { selectedID != nil && store.rows.contains { $0.id == selectedID } },
            set: { shown in if !shown { selectedID = nil } }
        )
    }

    private func timeHelp(for row: FlowRow) -> String {
        var help = row.lastSeenAt.formatted(date: .abbreviated, time: .standard)
        if row.count > 1 {
            help += " — \(row.count) flows since \(Self.timeFormatter.string(from: row.startedAt))"
        }
        if row.preexisting {
            help += " (started before launch)"
        }
        return help
    }

    private func trafficText(for row: FlowRow) -> String {
        guard row.txBytes > 0 || row.rxBytes > 0 else { return "—" }
        return "↑\(Self.byteFormatter.string(fromByteCount: Int64(row.txBytes))) ↓\(Self.byteFormatter.string(fromByteCount: Int64(row.rxBytes)))"
    }

    @ViewBuilder
    private func statusBar(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
            if store.isPaused {
                Label("Paused — \(store.pausedBufferCount) buffered", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Live", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            dnsStatusLabel
            Spacer()
            Text("\(visibleCount) shown · \(store.rows.count) flows · \(store.totalSeen) seen")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var dnsStatusLabel: some View {
        switch store.dnsStatus {
        case .active(let interface):
            Label("DNS names on (\(interface))", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .help("Capturing DNS responses — flows show the real hostnames apps requested.")
        case .denied:
            Label("DNS names off", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
                .help("True hostnames need BPF access. Run scripts/install-bpf-helper.sh once, then relaunch. Until then, hostnames come from reverse DNS.")
        case .unavailable(let reason):
            Label("DNS names off", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help("DNS capture unavailable: \(reason). Falling back to reverse DNS.")
        case .inactive:
            EmptyView()
        }
    }
}

/// App icon for GUI processes, a gear for daemons. Cached per pid.
struct ProcessIcon: View {
    let pid: Int32

    private static var cache: [Int32: NSImage] = [:]

    var body: some View {
        if let icon = Self.icon(for: pid) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
        }
    }

    private static func icon(for pid: Int32) -> NSImage? {
        if let cached = cache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon else {
            return nil
        }
        cache[pid] = icon
        return icon
    }
}
