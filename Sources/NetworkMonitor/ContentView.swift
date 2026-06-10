import AppKit
import SwiftUI

enum ViewMode: String, CaseIterable {
    case list, domains, map

    var label: String {
        switch self {
        case .list: "List"
        case .domains: "Domains"
        case .map: "Map"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .domains: "rectangle.3.group"
        case .map: "map"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: FlowStore
    @State private var searchText = ""
    @State private var selectedID: FlowRow.ID?
    @AppStorage("viewMode") private var viewMode = ViewMode.list
    @State private var showingSetup = false

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

        content(visible)
            // Footer goes under the main content only, before .inspector, so
            // it doesn't span across (and clip the bottom of) the inspector
            // pane, which gets its own full-height scroll.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar(visibleCount: visible.count)
            }
            .onExitCommand { if selectedID != nil { selectedID = nil } }
            .inspector(isPresented: inspectorShown) {
                if let row = store.row(selectedID) {
                    FlowDetailView(row: row)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by process, host, port, type")
            .toolbar { toolbarItems }
            .navigationTitle("Network Monitor")
            .sheet(isPresented: $showingSetup) {
                SetupView().environmentObject(store)
            }
    }

    @ViewBuilder
    private func content(_ visible: [FlowRow]) -> some View {
        switch viewMode {
        case .list: flowTable(visible)
        case .domains: DomainGroupedView(rows: visible, selectedID: $selectedID)
        case .map: FlowsMapView(rows: visible)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between list, domain-grouped, and map views")
        }
        ToolbarItemGroup {
            Button { store.togglePause() } label: {
                Label(store.isPaused ? "Resume" : "Pause",
                      systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            .help(store.isPaused ? "Resume live capture (⌘.)" : "Pause the feed (⌘.)")

            Button { store.clear() } label: {
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

    @ViewBuilder
    private func flowTable(_ visible: [FlowRow]) -> some View {
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
                    ProcessIcon(pid: row.pid, path: row.processPath)
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
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { store.row(selectedID) != nil },
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
            Button { showingSetup = true } label: {
                dnsStatusLabel
            }
            .buttonStyle(.plain)
            .help("Open Setup")
            Spacer()
            Text("\(visibleCount) shown · \(store.rows.count) flows · \(store.totalSeen) seen")
                .foregroundStyle(.secondary)
            Button { showingSetup = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Setup — hostnames & location data")
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
                .help("True hostnames need BPF access. Click to open Setup and enable it. Until then, hostnames come from reverse DNS.")
        case .unavailable(let reason):
            Label("DNS names off", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help("DNS capture unavailable: \(reason). Falling back to reverse DNS.")
        case .inactive:
            EmptyView()
        }
    }
}

/// App icon for a process, with a gear fallback for true daemons.
///
/// GUI apps resolve directly via NSRunningApplication. Helper/child processes
/// (e.g. "Google Chrome Helper") aren't registered applications and have no
/// icon of their own, so we walk their executable path up to the enclosing
/// top-level `.app` bundle and use *its* icon — so Chrome helpers show the
/// Chrome icon. Results are cached, including misses, so each process and each
/// bundle is resolved at most once.
struct ProcessIcon: View {
    let pid: Int32
    var path: String?

    // `NSImage?` value (not just presence) so misses are cached too — daemons
    // would otherwise re-hit LaunchServices on every render.
    private static var byPID: [Int32: NSImage?] = [:]
    private static var byBundle: [String: NSImage?] = [:]

    var body: some View {
        if let icon = Self.icon(pid: pid, path: path) {
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

    private static func icon(pid: Int32, path: String?) -> NSImage? {
        if let cached = byPID[pid] { return cached }

        // A registered GUI app (e.g. Spotify) has its own icon by PID.
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            byPID[pid] = icon
            return icon
        }

        // Otherwise fall back to the enclosing top-level app bundle's icon.
        let resolved = path.flatMap(topLevelAppBundle(forPath:)).flatMap(bundleIcon(forPath:))
        byPID[pid] = resolved
        return resolved
    }

    /// "/Applications/Google Chrome.app/…/Helper.app/Contents/MacOS/Helper"
    /// → "/Applications/Google Chrome.app" (the outermost .app, not the helper).
    private static func topLevelAppBundle(forPath path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[0...index].joined(separator: "/")
    }

    private static func bundleIcon(forPath bundlePath: String) -> NSImage? {
        if let cached = byBundle[bundlePath] { return cached }
        let icon = FileManager.default.fileExists(atPath: bundlePath)
            ? NSWorkspace.shared.icon(forFile: bundlePath)
            : nil
        byBundle[bundlePath] = icon
        return icon
    }
}
