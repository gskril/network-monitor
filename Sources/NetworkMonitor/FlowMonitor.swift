import Foundation

/// Owns the NStat manager and turns its callbacks into FlowEvent values.
/// All framework callbacks arrive on `queue`; the event handler is invoked
/// on that queue and must hop threads itself.
final class FlowMonitor {
    enum Event {
        case description(id: UInt64, FlowDescription, receivedAt: Date)
        case removed(id: UInt64)
    }

    private let queue = DispatchQueue(label: "com.greg.networkmonitor.nstat")
    private let onEvent: (Event) -> Void
    private var manager: UnsafeMutableRawPointer?
    private var activeSources: [UnsafeMutableRawPointer: UInt64] = [:]
    private var nextID: UInt64 = 1
    private var refreshTimer: DispatchSourceTimer?

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard manager == nil else { return }
        guard let manager = NStat.createManager(queue: queue, onSource: { [weak self] source in
            guard let self, let source else { return }
            self.register(source: source)
        }) else {
            NSLog("NStatManagerCreate failed — no flow data available")
            return
        }
        self.manager = manager
        _ = NStat.addAllTCP(manager)
        _ = NStat.addAllUDP(manager)

        // Periodically refresh all source descriptions so byte counts tick and
        // late-resolving remote addresses fill in.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, let manager = self.manager else { return }
            NStat.queryAllDescriptions(manager)
        }
        timer.resume()
        refreshTimer = timer
    }

    private func register(source: UnsafeMutableRawPointer) {
        let id = nextID
        nextID += 1
        activeSources[source] = id

        NStat.setDescriptionBlock(source) { [weak self] description in
            guard let self, let dict = description as? [String: Any] else { return }
            self.onEvent(.description(id: id, FlowDescription(dictionary: dict), receivedAt: Date()))
        }
        NStat.setRemovedBlock(source) { [weak self] in
            guard let self else { return }
            self.activeSources.removeValue(forKey: source)
            self.onEvent(.removed(id: id))
        }
        NStat.queryDescription(source)

        // A brand-new flow's first description often has an unresolved remote
        // address ([::]:0). Re-query shortly after so short-lived flows still
        // get attributed before they disappear.
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.activeSources[source] == id else { return }
            NStat.queryDescription(source)
        }
    }
}
