import Foundation
import Network
import AppCore

/// Reports the device's network path (whether it works, which interfaces) to `ConnectionRecheck`,
/// as the Mac's `ConnectionWatcher` does: Wi-Fi to cellular, a VPN such as Tailscale coming up.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private let onChange: @MainActor (ConnectionRecheck.PathSummary) -> Void

    init(onChange: @escaping @MainActor (ConnectionRecheck.PathSummary) -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = ConnectionRecheck.PathSummary(satisfied: path.status == .satisfied,
                                                        interfaces: path.availableInterfaces.map(\.name))
            Task { @MainActor in self?.onChange(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "SwiftSSH.NetworkWatcher"))
    }

    func stop() {
        monitor.cancel()
    }
}
