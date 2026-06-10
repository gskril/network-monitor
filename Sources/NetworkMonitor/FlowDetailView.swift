import MapKit
import SwiftUI

/// Inspector panel showing everything the kernel exposes about a flow.
struct FlowDetailView: View {
    let row: FlowRow
    @State private var copied = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ProcessIcon(pid: row.pid, path: row.processPath)
                        .scaleEffect(2)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.processName)
                            .font(.headline)
                        Text("PID \(String(row.pid))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        copyToPasteboard()
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy all details for this connection (e.g. to paste into a chat)")
                }
                if let path = row.processPath {
                    verticalRow("Path", path, font: .caption.monospaced())
                }
            }

            Section("Connection") {
                LabeledContent("Type") {
                    Text(row.kind.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(row.kind.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(row.kind.color)
                }
                LabeledContent("Protocol", value: row.provider)
                LabeledContent("State", value: row.stateDisplay)
                if row.count > 1 {
                    LabeledContent("Coalesced flows", value: "\(row.count) (\(row.openCount) open)")
                }
                LabeledContent("Interface", value: interfaceText)
            }

            Section("Remote") {
                if let host = row.remoteHost {
                    verticalRow(row.remoteHostAuthoritative ? "Hostname (from DNS)" : "Hostname (reverse DNS)", host)
                }
                if let remote = row.remote, !remote.isUnspecified {
                    verticalRow("Address", remote.ip)
                    LabeledContent("Port", value: String(remote.port))
                } else {
                    Text("No remote endpoint (unconnected socket)")
                        .foregroundStyle(.secondary)
                }
                if let local = row.local {
                    verticalRow("Local", "\(local.ip):\(local.port)")
                }
            }

            Section("Activity") {
                LabeledContent("First seen", value: row.startedAt.formatted(date: .omitted, time: .standard))
                LabeledContent("Last seen", value: row.lastSeenAt.formatted(date: .omitted, time: .standard))
                LabeledContent("Duration", value: durationText)
                if row.preexisting {
                    Text("Flow started before this app launched")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Traffic") {
                LabeledContent("Sent", value: trafficText(bytes: row.txBytes, packets: row.stats.txPackets))
                LabeledContent("Received", value: trafficText(bytes: row.rxBytes, packets: row.stats.rxPackets))
                if row.stats.retransmittedBytes > 0 {
                    LabeledContent("Retransmitted", value: Self.byteFormatter.string(fromByteCount: Int64(row.stats.retransmittedBytes)))
                }
                if row.stats.rxDuplicateBytes > 0 {
                    LabeledContent("Duplicate", value: Self.byteFormatter.string(fromByteCount: Int64(row.stats.rxDuplicateBytes)))
                }
                if row.stats.rxOutOfOrderBytes > 0 {
                    LabeledContent("Out of order", value: Self.byteFormatter.string(fromByteCount: Int64(row.stats.rxOutOfOrderBytes)))
                }
            }

            if row.stats.rttAverage != nil || row.stats.congestionAlgorithm != nil {
                Section("Quality") {
                    if let rtt = row.stats.rttAverage {
                        LabeledContent("RTT (avg)", value: rttText(rtt))
                    }
                    if let rtt = row.stats.rttMinimum {
                        LabeledContent("RTT (min)", value: rttText(rtt))
                    }
                    if let rtt = row.stats.rttVariation {
                        LabeledContent("RTT (variation)", value: rttText(rtt))
                    }
                    if let algorithm = row.stats.congestionAlgorithm {
                        LabeledContent("Congestion control", value: algorithm)
                    }
                }
            }

            if let location = row.location {
                Section("Estimated region") {
                    LabeledContent("Location") {
                        Text("\(Self.flag(location.countryCode)) \(row.regionDisplay ?? "Unknown")")
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Coordinates",
                                   value: String(format: "%.3f, %.3f", location.latitude, location.longitude))
                    FlowMiniMap(coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude, longitude: location.longitude))
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets())
                    Text("Approximate server location from an offline IP database — city-level and not exact.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if showsPayloadNote {
                Section {
                    Label {
                        Text("Request headers and content aren't visible: this app passively observes flow metadata, and TLS encrypts payloads. Inspecting HTTP would require a local MITM proxy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var interfaceText: String {
        var parts: [String] = []
        if let name = row.interfaceName { parts.append(name) }
        if let kind = row.stats.interfaceKind { parts.append(kind) }
        if row.stats.isExpensiveInterface { parts.append("expensive") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var durationText: String {
        let end = row.isClosed ? row.lastSeenAt : Date()
        let seconds = max(0, end.timeIntervalSince(row.startedAt))
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s" }
        return "\(Int(seconds) / 3600)h \((Int(seconds) % 3600) / 60)m"
    }

    private var showsPayloadNote: Bool {
        switch row.kind {
        case .https, .http, .quic: true
        default: false
        }
    }

    private func trafficText(bytes: UInt64, packets: UInt64) -> String {
        var text = Self.byteFormatter.string(fromByteCount: Int64(bytes))
        if packets > 0 {
            text += " · \(packets) pkts"
        }
        return text
    }

    private func rttText(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText(), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// A plain-text dump of everything known about the flow, suitable for
    /// pasting into a chat or bug report. Only includes fields that have data.
    private func copyableText() -> String {
        let timestamp = DateFormatter()
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var lines: [String] = ["Network Monitor — connection details"]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label): \(value)") }
        }

        add("Process", "\(row.processName) (PID \(row.pid))")
        add("Path", row.processPath)
        add("Type", "\(row.kind.rawValue) (\(row.provider))")
        add("State", row.stateDisplay)
        if row.count > 1 { add("Coalesced flows", "\(row.count) (\(row.openCount) open)") }
        add("Interface", interfaceText == "—" ? nil : interfaceText)

        if row.remoteHost != nil {
            add(row.remoteHostAuthoritative ? "Hostname (from DNS)" : "Hostname (reverse DNS)", row.remoteHost)
        }
        if let remote = row.remote, !remote.isUnspecified {
            add("Remote", "\(remote.ip):\(remote.port)")
        }
        if let local = row.local { add("Local", "\(local.ip):\(local.port)") }

        if let location = row.location {
            add("Estimated region", "\(row.regionDisplay ?? "Unknown") (\(String(format: "%.3f, %.3f", location.latitude, location.longitude)))")
        }

        add("First seen", timestamp.string(from: row.startedAt))
        add("Last seen", timestamp.string(from: row.lastSeenAt))
        add("Duration", durationText)

        add("Sent", trafficText(bytes: row.txBytes, packets: row.stats.txPackets))
        add("Received", trafficText(bytes: row.rxBytes, packets: row.stats.rxPackets))
        if row.stats.retransmittedBytes > 0 {
            add("Retransmitted", Self.byteFormatter.string(fromByteCount: Int64(row.stats.retransmittedBytes)))
        }
        if let rtt = row.stats.rttAverage { add("RTT (avg)", rttText(rtt)) }
        if let rtt = row.stats.rttMinimum { add("RTT (min)", rttText(rtt)) }
        add("Congestion control", row.stats.congestionAlgorithm)

        return lines.joined(separator: "\n")
    }

    /// Regional-indicator flag emoji from an ISO 3166-1 alpha-2 code.
    static func flag(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "🏳️" }
        let base: UInt32 = 127397 // 0x1F1E6 - 'A'
        var scalars = String.UnicodeScalarView()
        for unicode in code.uppercased().unicodeScalars {
            guard let scalar = UnicodeScalar(base + unicode.value) else { return "🏳️" }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Label-above-value layout for values too long to share a line with
    /// their label (hostnames, paths, addresses).
    @ViewBuilder
    private func verticalRow(_ label: String, _ value: String, font: Font = .body.monospaced()) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}
