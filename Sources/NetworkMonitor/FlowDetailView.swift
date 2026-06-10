import SwiftUI

/// Inspector panel showing everything the kernel exposes about a flow.
struct FlowDetailView: View {
    let row: FlowRow

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ProcessIcon(pid: row.pid)
                        .scaleEffect(2)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.processName)
                            .font(.headline)
                        Text("PID \(String(row.pid))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    verticalRow("Hostname", host)
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
