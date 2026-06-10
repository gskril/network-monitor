import Foundation
import SwiftUI

/// Main-actor model behind the UI. Monitor events are buffered on the
/// monitor's queue and applied in coalesced batches so a burst of flow
/// updates doesn't trigger thousands of SwiftUI invalidations.
@MainActor
final class FlowStore: ObservableObject {
    @Published private(set) var rows: [FlowRow] = []
    @Published private(set) var totalSeen = 0
    @Published var isPaused = false {
        didSet { if !isPaused { flush() } }
    }

    @AppStorage("showLoopback") var showLoopback = false
    @AppStorage("showUnconnected") var showUnconnected = false
    @AppStorage("showPreexisting") var showPreexisting = true

    private let maxRows = 5000
    private var byID: [UInt64: FlowRow] = [:]
    private var order: [UInt64] = [] // newest first
    private var dnsInFlight: Set<String> = []
    private let launchDate = Date()

    private let pending = PendingEvents()
    private var monitor: FlowMonitor?
    private var flushTimer: Timer?

    func start() {
        guard monitor == nil else { return }
        let pending = pending
        let monitor = FlowMonitor { event in
            pending.append(event)
        }
        self.monitor = monitor
        monitor.start()

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPaused else { return }
                self.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    var pausedBufferCount: Int { pending.count }

    func togglePause() {
        isPaused.toggle()
    }

    func clear() {
        byID.removeAll()
        order.removeAll()
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

    private func flush() {
        let events = pending.drain()
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .description(let id, let description, let receivedAt):
                apply(id: id, description: description, receivedAt: receivedAt)
            case .removed(let id):
                if var row = byID[id] {
                    row.isClosed = true
                    byID[id] = row
                }
            }
        }
        if order.count > maxRows {
            let dropped = order[maxRows...]
            for id in dropped { byID.removeValue(forKey: id) }
            order.removeSubrange(maxRows...)
        }
        rows = order.compactMap { byID[$0] }
    }

    private func apply(id: UInt64, description: FlowDescription, receivedAt: Date) {
        if var row = byID[id] {
            if let remote = description.remote { row.remote = remote }
            if let state = description.tcpState { row.tcpState = state }
            if let rx = description.rxBytes { row.rxBytes = rx }
            if let tx = description.txBytes { row.txBytes = tx }
            if let index = description.interfaceIndex, row.interfaceName == nil {
                row.interfaceName = interfaceName(forIndex: index)
            }
            row.kind = FlowKind.classify(
                provider: description.provider ?? row.provider,
                tcpState: row.tcpState,
                remote: row.remote,
                local: row.local
            )
            byID[id] = row
            resolveHostIfNeeded(for: row)
        } else {
            // The kernel's start stamp is coarse, so flows discovered together
            // would collide; arrival time is exact for flows born after launch.
            let kernelStart = description.startMachTime.map(MachTime.toDate)
            let preexisting = (kernelStart ?? receivedAt) < launchDate.addingTimeInterval(-1)
            let startedAt = preexisting ? (kernelStart ?? receivedAt) : receivedAt
            let row = FlowRow(
                id: id,
                startedAt: startedAt,
                preexisting: preexisting,
                processName: description.processName ?? "unknown",
                pid: description.pid ?? 0,
                provider: description.provider ?? "?",
                tcpState: description.tcpState,
                local: description.local,
                remote: description.remote,
                remoteHost: nil,
                interfaceName: description.interfaceIndex.flatMap(interfaceName(forIndex:)),
                rxBytes: description.rxBytes ?? 0,
                txBytes: description.txBytes ?? 0,
                isClosed: false,
                kind: FlowKind.classify(
                    provider: description.provider,
                    tcpState: description.tcpState,
                    remote: description.remote,
                    local: description.local
                )
            )
            byID[id] = row
            insertSorted(id: id, startedAt: startedAt)
            totalSeen += 1
            resolveHostIfNeeded(for: row)
        }
    }

    private func insertSorted(id: UInt64, startedAt: Date) {
        // New flows are almost always the newest, so scan from the front.
        var index = 0
        while index < order.count, let existing = byID[order[index]], existing.startedAt > startedAt {
            index += 1
        }
        order.insert(id, at: index)
    }

    private func resolveHostIfNeeded(for row: FlowRow) {
        guard row.hasRemote, row.remoteHost == nil, let remote = row.remote else { return }
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
