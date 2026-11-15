import Foundation
import Network
import AppKit

/// Tells the app when its open connections may have died without a word: the Mac's network changed
/// (Wi-Fi off or switched, cable, VPN such as Tailscale) or the Mac woke from sleep. The app then has
/// every session check its server at once (`SessionManager.checkConnections`) instead of waiting for
/// the next keep-alive.
@MainActor
final class ConnectionWatcher {
    private let onChange: @MainActor () -> Void
    private let monitor = NWPathMonitor()
    private var lastPath: PathSummary?
    private var wakeObserver: NSObjectProtocol?

    /// What matters about a network path: whether it works and which interfaces it uses.
    private struct PathSummary: Equatable {
        var satisfied: Bool
        var interfaces: [String]
    }

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = PathSummary(satisfied: path.status == .satisfied,
                                      interfaces: path.availableInterfaces.map(\.name))
            Task { @MainActor in self?.pathChanged(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectionWatcher.path"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// The first report is the starting state; a later one that differs means the network changed.
    /// Sessions are checked once the network works again (checking while it is down would end
    /// sessions that survive a quick Wi-Fi switch; a lasting outage is caught by the keep-alive).
    private func pathChanged(_ summary: PathSummary) {
        defer { lastPath = summary }
        guard let lastPath, lastPath != summary, summary.satisfied else { return }
        onChange()
    }

    /// After a wake the network takes a moment to come back: check a few seconds later, when it works.
    private func woke() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.lastPath?.satisfied ?? true else { return }
            self.onChange()
        }
    }
}
