import Foundation
import SwiftUI

/// Main-actor model behind the UI. Monitor events are buffered on the
/// monitor's queue and applied in coalesced batches so a burst of flow
/// updates doesn't trigger thousands of SwiftUI invalidations.
///
/// Repeated identical flows (same process → same remote endpoint, within
/// `mergeWindow`) collapse into one row with a ×N counter instead of
/// flooding the list — e.g. a process firing 20 UDP probes in a burst.
@MainActor
final class FlowStore: ObservableObject {
    @Published private(set) var rows: [FlowRow] = []
    @Published private(set) var totalSeen = 0
    @Published private(set) var dnsStatus: DNSSniffer.Status = .inactive
    @Published var isPaused = false {
        didSet { if !isPaused { flush() } }
    }

    @AppStorage("showLoopback") var showLoopback = false
    @AppStorage("showUnconnected") var showUnconnected = false
    @AppStorage("showPreexisting") var showPreexisting = true

    private let maxRows = 5000
    private let mergeWindow: TimeInterval = 30

    private var byID: [UInt64: FlowRow] = [:]          // row id → row
    private var order: [UInt64] = []                   // row ids, newest activity first
    private var sourceToRow: [UInt64: UInt64] = [:]    // kernel source id → row id
    private var sourceTraffic: [UInt64: TrafficCounters] = [:]
    private var keyToRow: [FlowKey: UInt64] = [:]      // coalescing target per identity
    private var pathByPID: [Int32: String?] = [:]
    private var dnsInFlight: Set<String> = []
    private let launchDate = Date()

    @Published private(set) var geoip: GeoIP? = GeoIP(path: GeoDataInstaller.dbPath)
    var geoAvailable: Bool { geoip != nil }

    private func geoLocation(for endpoint: Endpoint) -> GeoIP.Location? {
        guard !endpoint.isUnspecified, !endpoint.isLoopback else { return nil }
        return geoip?.lookup(endpoint.ip)
    }

    /// Re-open the location database (after a download) and back-fill any rows
    /// that don't have a location yet, so the map populates without a relaunch.
    func reloadGeoIP() {
        geoip = GeoIP(path: GeoDataInstaller.dbPath)
        guard geoip != nil else { return }
        var changed = false
        for (id, var row) in byID where row.location == nil {
            if let remote = row.remote, let location = geoLocation(for: remote) {
                row.location = location
                byID[id] = row
                changed = true
            }
        }
        if changed { rows = order.compactMap { byID[$0] } }
    }

    private let pending = PendingEvents()
    private var monitor: FlowMonitor?
    private var sniffer: DNSSniffer?
    private var flushTimer: Timer?

    func start() {
        guard monitor == nil else { return }
        let pending = pending
        let monitor = FlowMonitor { event in
            pending.append(event)
        }
        self.monitor = monitor
        monitor.start()

        let sniffer = DNSSniffer(
            onLearn: { [weak self] mapping in
                Task { @MainActor [weak self] in self?.applyLearnedHost(ip: mapping.ip, host: mapping.host) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in self?.dnsStatus = status }
            }
        )
        self.sniffer = sniffer
        sniffer.start()

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPaused else { return }
                self.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func shutdown() {
        sniffer?.stop()
    }

    /// A DNS response taught us this IP's real hostname; relabel any rows that
    /// have it (overriding reverse-DNS guesses).
    private func applyLearnedHost(ip: String, host: String) {
        var changed = false
        for (id, var row) in byID where row.remote?.ip == ip && !row.remoteHostAuthoritative {
            row.remoteHost = host
            row.remoteHostAuthoritative = true
            byID[id] = row
            changed = true
        }
        if changed { rows = order.compactMap { byID[$0] } }
    }

    var pausedBufferCount: Int { pending.count }

    func togglePause() {
        isPaused.toggle()
    }

    func clear() {
        byID.removeAll()
        order.removeAll()
        sourceToRow.removeAll()
        sourceTraffic.removeAll()
        keyToRow.removeAll()
        rows = []
    }

    func filteredRows(searchText: String) -> [FlowRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            if !showLoopback && row.isLoopback { return false }
            if !showUnconnected && !row.hasRemote { return false }
            if !showPreexisting && row.preexisting { return false }
            guard !needle.isEmpty else { return true }
            return row.processName.lowercased().contains(needle)
                || row.remoteDisplay.lowercased().contains(needle)
                || (row.remote.map { $0.ip.lowercased().contains(needle) || String($0.port).contains(needle) } ?? false)
                || row.kind.rawValue.lowercased().contains(needle)
        }
    }

    // MARK: - Event application

    private func flush() {
        let events = pending.drain()
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .description(let id, let description, let receivedAt):
                apply(sourceID: id, description: description, receivedAt: receivedAt)
            case .removed(let id):
                applyRemoval(sourceID: id)
            }
        }
        pruneIfNeeded()
        rows = order.compactMap { byID[$0] }
    }

    private func apply(sourceID: UInt64, description: FlowDescription, receivedAt: Date) {
        if let rowID = sourceToRow[sourceID] {
            update(rowID: rowID, sourceID: sourceID, with: description)
        } else {
            addSource(sourceID: sourceID, description: description, receivedAt: receivedAt)
        }
    }

    private func addSource(sourceID: UInt64, description: FlowDescription, receivedAt: Date) {
        totalSeen += 1
        let key = makeKey(description: description)

        // Coalesce into an existing row for the same identity seen recently.
        if let key, let targetID = keyToRow[key], var target = byID[targetID],
           receivedAt.timeIntervalSince(target.lastSeenAt) < mergeWindow {
            sourceToRow[sourceID] = targetID
            target.count += 1
            target.openCount += 1
            target.members.append(sourceID)
            target.lastSeenAt = receivedAt
            target.isClosed = false
            if let state = description.tcpState { target.tcpState = state }
            byID[targetID] = target
            addTrafficDelta(rowID: targetID, sourceID: sourceID, description: description)
            bump(rowID: targetID)
            return
        }

        // The kernel's start stamp is coarse, so flows discovered together
        // would collide; arrival time is exact for flows born after launch.
        let kernelStart = description.startMachTime.map(MachTime.toDate)
        let preexisting = (kernelStart ?? receivedAt) < launchDate.addingTimeInterval(-1)
        let startedAt = preexisting ? (kernelStart ?? receivedAt) : receivedAt

        var row = FlowRow(
            id: sourceID,
            startedAt: startedAt,
            lastSeenAt: startedAt,
            count: 1,
            openCount: 1,
            members: [sourceID],
            key: key,
            preexisting: preexisting,
            processPath: description.pid.flatMap(cachedProcessPath(forPID:)),
            processName: description.processName ?? "unknown",
            pid: description.pid ?? 0,
            provider: description.provider ?? "?",
            tcpState: description.tcpState,
            local: description.local,
            remote: description.remote,
            remoteHost: nil,
            location: description.remote.flatMap(geoLocation(for:)),
            interfaceName: description.interfaceIndex.flatMap(interfaceName(forIndex:)),
            rxBytes: 0,
            txBytes: 0,
            isClosed: false,
            kind: .udp
        )
        row.kind = classify(description: description, row: row)
        byID[sourceID] = row
        sourceToRow[sourceID] = sourceID
        if let key { keyToRow[key] = sourceID }
        insertSorted(id: sourceID, lastSeenAt: row.lastSeenAt)
        addTrafficDelta(rowID: sourceID, sourceID: sourceID, description: description)
        resolveHostIfNeeded(for: row)
    }

    private func update(rowID: UInt64, sourceID: UInt64, with description: FlowDescription) {
        guard var row = byID[rowID] else { return }

        let hadRemote = row.hasRemote
        if let remote = description.remote { row.remote = remote }
        if row.location == nil, let remote = row.remote { row.location = geoLocation(for: remote) }
        if let state = description.tcpState { row.tcpState = state }
        if let index = description.interfaceIndex, row.interfaceName == nil {
            row.interfaceName = interfaceName(forIndex: index)
        }
        row.kind = classify(description: description, row: row)

        // The flow's remote endpoint just resolved: it now has a coalescing
        // identity. Merge into a recent matching row, or register as the
        // coalescing target for future repeats.
        if !hadRemote, row.hasRemote, row.key == nil, let key = makeKey(description: description, fallback: row) {
            if let targetID = keyToRow[key], targetID != rowID, var target = byID[targetID],
               row.lastSeenAt.timeIntervalSince(target.lastSeenAt) < mergeWindow {
                target.count += row.count
                target.openCount += row.openCount
                target.members.append(contentsOf: row.members)
                target.lastSeenAt = max(target.lastSeenAt, row.lastSeenAt)
                target.isClosed = false
                target.rxBytes += row.rxBytes
                target.txBytes += row.txBytes
                target.stats.absorbCounters(of: row.stats)
                if let state = row.tcpState { target.tcpState = state }
                byID[targetID] = target
                for member in row.members { sourceToRow[member] = targetID }
                byID.removeValue(forKey: rowID)
                order.removeAll { $0 == rowID }
                addTrafficDelta(rowID: targetID, sourceID: sourceID, description: description)
                bump(rowID: targetID)
                return
            }
            row.key = key
            keyToRow[key] = rowID
        }

        byID[rowID] = row
        addTrafficDelta(rowID: rowID, sourceID: sourceID, description: description)
        resolveHostIfNeeded(for: row)
    }

    private func applyRemoval(sourceID: UInt64) {
        sourceTraffic.removeValue(forKey: sourceID)
        guard let rowID = sourceToRow.removeValue(forKey: sourceID), var row = byID[rowID] else { return }
        row.openCount -= 1
        if row.openCount <= 0 {
            row.openCount = 0
            row.isClosed = true
        }
        byID[rowID] = row
    }

    /// Traffic counters arrive as per-source cumulative totals; rows
    /// accumulate deltas so coalesced rows show the group's combined traffic.
    private func addTrafficDelta(rowID: UInt64, sourceID: UInt64, description: FlowDescription) {
        let current = TrafficCounters(description: description)
        let last = sourceTraffic[sourceID] ?? TrafficCounters()
        sourceTraffic[sourceID] = current
        guard var row = byID[rowID] else { return }
        row.rxBytes += current.rxBytes.subtractingOrZero(last.rxBytes)
        row.txBytes += current.txBytes.subtractingOrZero(last.txBytes)
        row.stats.rxPackets += current.rxPackets.subtractingOrZero(last.rxPackets)
        row.stats.txPackets += current.txPackets.subtractingOrZero(last.txPackets)
        row.stats.retransmittedBytes += current.retransmitted.subtractingOrZero(last.retransmitted)
        row.stats.rxDuplicateBytes += current.duplicate.subtractingOrZero(last.duplicate)
        row.stats.rxOutOfOrderBytes += current.outOfOrder.subtractingOrZero(last.outOfOrder)
        row.stats.updateQuality(from: description)
        byID[rowID] = row
    }

    private func cachedProcessPath(forPID pid: Int32) -> String? {
        if let cached = pathByPID[pid] { return cached }
        let path = processPath(forPID: pid)
        pathByPID[pid] = path
        return path
    }

    private func makeKey(description: FlowDescription, fallback: FlowRow? = nil) -> FlowKey? {
        guard let remote = description.remote ?? fallback?.remote,
              !remote.isUnspecified, remote.port != 0 else { return nil }
        return FlowKey(
            pid: description.pid ?? fallback?.pid ?? 0,
            processName: description.processName ?? fallback?.processName ?? "unknown",
            remoteIP: remote.ip,
            remotePort: remote.port,
            provider: description.provider ?? fallback?.provider ?? "?"
        )
    }

    private func classify(description: FlowDescription, row: FlowRow) -> FlowKind {
        FlowKind.classify(
            provider: description.provider ?? row.provider,
            tcpState: description.tcpState ?? row.tcpState,
            remote: description.remote ?? row.remote,
            local: description.local ?? row.local
        )
    }

    // MARK: - Ordering

    private func insertSorted(id: UInt64, lastSeenAt: Date) {
        // New activity is almost always the newest, so scan from the front.
        var index = 0
        while index < order.count, let existing = byID[order[index]], existing.lastSeenAt > lastSeenAt {
            index += 1
        }
        order.insert(id, at: index)
    }

    /// Moves a row that just saw new activity back to its sorted position
    /// (usually the top).
    private func bump(rowID: UInt64) {
        guard let row = byID[rowID] else { return }
        order.removeAll { $0 == rowID }
        insertSorted(id: rowID, lastSeenAt: row.lastSeenAt)
    }

    private func pruneIfNeeded() {
        guard order.count > maxRows else { return }
        let dropped = order[maxRows...]
        for rowID in dropped {
            guard let row = byID.removeValue(forKey: rowID) else { continue }
            for member in row.members {
                sourceToRow.removeValue(forKey: member)
                sourceTraffic.removeValue(forKey: member)
            }
            if let key = row.key, keyToRow[key] == rowID {
                keyToRow.removeValue(forKey: key)
            }
        }
        order.removeSubrange(maxRows...)
    }

    // MARK: - Reverse DNS

    private func resolveHostIfNeeded(for row: FlowRow) {
        guard row.hasRemote, let remote = row.remote else { return }

        // Prefer an authoritative name the DNS sniffer already captured.
        if !row.remoteHostAuthoritative, let host = DNSCache.shared.host(for: remote.ip) {
            applyLearnedHost(ip: remote.ip, host: host)
            return
        }
        guard row.remoteHost == nil else { return }
        guard !dnsInFlight.contains(remote.ip) else { return }
        dnsInFlight.insert(remote.ip)
        Task { [weak self] in
            let host = await ReverseDNS.shared.resolve(remote)
            await MainActor.run {
                guard let self else { return }
                self.dnsInFlight.remove(remote.ip)
                guard let host else { return }
                var changed = false
                for (id, var candidate) in self.byID where candidate.remote?.ip == remote.ip && candidate.remoteHost == nil {
                    candidate.remoteHost = host
                    self.byID[id] = candidate
                    changed = true
                }
                if changed {
                    self.rows = self.order.compactMap { self.byID[$0] }
                }
            }
        }
    }
}

/// Cumulative per-source counters used to compute per-update deltas.
private struct TrafficCounters {
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    var rxPackets: UInt64 = 0
    var txPackets: UInt64 = 0
    var retransmitted: UInt64 = 0
    var duplicate: UInt64 = 0
    var outOfOrder: UInt64 = 0

    init() {}

    init(description: FlowDescription) {
        rxBytes = description.rxBytes ?? 0
        txBytes = description.txBytes ?? 0
        rxPackets = description.rxPackets ?? 0
        txPackets = description.txPackets ?? 0
        retransmitted = description.retransmittedBytes ?? 0
        duplicate = description.rxDuplicateBytes ?? 0
        outOfOrder = description.rxOutOfOrderBytes ?? 0
    }
}

private extension UInt64 {
    func subtractingOrZero(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

/// Thread-safe event buffer bridging the monitor queue to the main actor.
final class PendingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FlowMonitor.Event] = []
    private let capacity = 20_000

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    func append(_ event: FlowMonitor.Event) {
        lock.lock(); defer { lock.unlock() }
        if events.count < capacity { events.append(event) }
    }

    func drain() -> [FlowMonitor.Event] {
        lock.lock(); defer { lock.unlock() }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }
}
