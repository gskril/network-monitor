import SwiftUI

/// Little Snitch-style hierarchy: process → registered domain → endpoints.
/// Most useful for browsers, where the flat list is dominated by one helper
/// process talking to many domains.
struct DomainGroupedView: View {
    let rows: [FlowRow]
    @Binding var selectedID: FlowRow.ID?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    var body: some View {
        List(selection: $selectedID) {
            ForEach(processNodes) { process in
                Section {
                    ForEach(process.domains) { domain in
                        DisclosureGroup {
                            ForEach(domain.endpoints) { endpoint in
                                endpointRow(endpoint)
                                    .tag(endpoint.id)
                            }
                        } label: {
                            domainLabel(domain)
                        }
                    }
                } header: {
                    processHeader(process)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Rows

    private func processHeader(_ process: ProcessNode) -> some View {
        HStack(spacing: 6) {
            ProcessIcon(pid: process.pid, path: process.path)
            Text(process.name).font(.headline)
            Text("·\u{00A0}\(process.connectionCount)")
                .foregroundStyle(.secondary)
            Spacer()
            Text(process.domains.count == 1 ? "1 domain" : "\(process.domains.count) domains")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func domainLabel(_ domain: DomainNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").foregroundStyle(.secondary).font(.caption)
            Text(domain.name).fontWeight(.medium)
            Spacer()
            if domain.bytes > 0 {
                Text(Self.byteFormatter.string(fromByteCount: Int64(domain.bytes)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("\(domain.endpoints.count)")
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private func endpointRow(_ endpoint: FlowRow) -> some View {
        HStack(spacing: 6) {
            Text(endpoint.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(endpoint.kind.color.opacity(0.18), in: Capsule())
                .foregroundStyle(endpoint.kind.color)
            Text(endpoint.remoteHost ?? endpoint.remote?.ip ?? "—")
                .lineLimit(1).truncationMode(.middle)
            if let port = endpoint.remote?.port {
                Text(":\(String(port))").foregroundStyle(.tertiary).font(.callout.monospaced())
            }
            Spacer()
            if let region = endpoint.regionDisplay {
                Text("\(FlowDetailView.flag(endpoint.location?.countryCode)) \(region)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(endpoint.stateDisplay)
                .font(.caption2)
                .foregroundStyle(endpoint.isClosed ? .tertiary : .secondary)
        }
    }

    // MARK: - Tree

    private struct ProcessNode: Identifiable {
        let id: String
        let pid: Int32
        let name: String
        let path: String?
        let connectionCount: Int
        let domains: [DomainNode]
    }

    private struct DomainNode: Identifiable {
        let id: String
        let name: String
        let bytes: UInt64
        let endpoints: [FlowRow]
    }

    private var processNodes: [ProcessNode] {
        // Group by process, preserving newest-first order by first appearance.
        var order: [Int32] = []
        var byPID: [Int32: [FlowRow]] = [:]
        for row in rows {
            if byPID[row.pid] == nil { order.append(row.pid) }
            byPID[row.pid, default: []].append(row)
        }
        return order.compactMap { pid in
            guard let group = byPID[pid], let first = group.first else { return nil }
            var domainOrder: [String] = []
            var byDomain: [String: [FlowRow]] = [:]
            for row in group {
                let key = row.domainGroup
                if byDomain[key] == nil { domainOrder.append(key) }
                byDomain[key, default: []].append(row)
            }
            let domains = domainOrder.map { key -> DomainNode in
                let endpoints = byDomain[key] ?? []
                let bytes = endpoints.reduce(UInt64(0)) { $0 + $1.rxBytes + $1.txBytes }
                return DomainNode(id: "\(pid)-\(key)", name: key, bytes: bytes, endpoints: endpoints)
            }
            return ProcessNode(
                id: "\(pid)-\(first.processName)",
                pid: pid,
                name: first.processName,
                path: first.processPath,
                connectionCount: group.reduce(0) { $0 + $1.count },
                domains: domains
            )
        }
    }
}
