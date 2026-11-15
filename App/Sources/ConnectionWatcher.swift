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
            MainActor.assumeIsolated { self?.onChange() }
        }
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// The first report is the starting state; later ones that differ mean the network changed.
    private func pathChanged(_ summary: PathSummary) {
        defer { lastPath = summary }
        guard let lastPath, lastPath != summary else { return }
        onChange()
    }
}
