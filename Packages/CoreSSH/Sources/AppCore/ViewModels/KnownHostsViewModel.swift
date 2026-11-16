import Foundation
import Observation
import CoreModels
import SSHCore

/// The Known Hosts screen: the trusted server keys (`KnownHost` records), one row per key, grouped
/// per host:port, with search and removal. Every read comes from the vault.
///
/// Removing a key tombstones it through `LocalVault.saveNow`, so the removal syncs; the next
/// connection to that address then asks to trust the key again (`KnownHostsStore.check`).
@MainActor @Observable
public final class KnownHostsViewModel {
    /// Filters `sections` by address, key type, fingerprint or the label of a saved host using the
    /// address (case-insensitive, surrounding spaces ignored).
    public var searchText = ""

    @ObservationIgnored private let vault: LocalVault
    @ObservationIgnored private let dateFormatter: DateFormatter

    public init(vault: LocalVault, timeZone: TimeZone = .current) {
        self.vault = vault
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM dd, yyyy"
        dateFormatter = formatter
    }

    /// A saved host whose address and port lead to a known host's address.
    public struct SavedHostRef: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// The host's label, or "Untitled host" when blank.
        public let label: String
    }

    /// One trusted key.
    public struct Row: Identifiable, Equatable {
        public let id: UUID
        /// As stored: `host` for port 22, else `[host]:port` (OpenSSH `known_hosts` form).
        public let hostPort: String
        /// As shown: `host`, or `host:port` when the port isn't 22.
        public let address: String
        public let keyType: String
        /// `SHA256:…`, as `ssh-keygen -l` prints it.
        public let fingerprint: String
        public let firstSeen: Date
        /// "Mar 04, 2026".
        public let firstSeenText: String
        /// Saved hosts that connect to this address (the same for every key of the address), A–Z.
        public let usedBy: [SavedHostRef]
    }

    /// The keys of one host:port.
    public struct Section: Identifiable, Equatable {
        public let hostPort: String
        public let address: String
        /// Key types A–Z (only matching keys while searching).
        public let rows: [Row]
        public let usedBy: [SavedHostRef]
        public var id: String { hostPort }
    }

    /// Live keys, search ignored: the sidebar's number.
    public var keyCount: Int {
        _ = vault.revision
        return vault.all(KnownHost.self).count
    }

    /// Distinct host:port values with live keys, search ignored.
    public var hostCount: Int {
        _ = vault.revision
        return Set(vault.all(KnownHost.self).map(\.hostPort)).count
    }

    /// Live keys of `hostPort` (stored form), search ignored: what "remove all" removes.
    public func keyCount(hostPort: String) -> Int {
        _ = vault.revision
        return vault.all(KnownHost.self).filter { $0.hostPort == hostPort }.count
    }

    /// One section per host:port, ordered by host A–Z (case-insensitive) then port; key types A–Z
    /// within each. While searching, only matching keys, and sections without any are left out.
    public var sections: [Section] {
        _ = vault.revision
        let usage = savedHostsByHostPort()
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let grouped = Dictionary(grouping: vault.all(KnownHost.self), by: \.hostPort)
        var result: [Section] = []
        for (hostPort, records) in grouped {
            let parts = Self.split(hostPort)
            let address = Self.displayAddress(host: parts.host, port: parts.port)
            let usedBy = usage[hostPort] ?? []
            let rows = records
                .sorted { a, b in
                    if a.keyType != b.keyType { return a.keyType < b.keyType }
                    if a.firstSeen != b.firstSeen { return a.firstSeen < b.firstSeen }
                    return a.id.uuidString < b.id.uuidString
                }
                .map { record in
                    Row(id: record.id, hostPort: hostPort, address: address, keyType: record.keyType,
                        fingerprint: record.fingerprintSHA256, firstSeen: record.firstSeen,
                        firstSeenText: dateFormatter.string(from: record.firstSeen), usedBy: usedBy)
                }
            let addressMatches = needle.isEmpty
                || address.localizedCaseInsensitiveContains(needle)
                || hostPort.localizedCaseInsensitiveContains(needle)
                || usedBy.contains { $0.label.localizedCaseInsensitiveContains(needle) }
            let shown = addressMatches ? rows : rows.filter {
                $0.keyType.localizedCaseInsensitiveContains(needle)
                    || $0.fingerprint.localizedCaseInsensitiveContains(needle)
            }
            guard !shown.isEmpty else { continue }
            result.append(Section(hostPort: hostPort, address: address, rows: shown, usedBy: usedBy))
        }
        return result.sorted { a, b in
            let pa = Self.split(a.hostPort), pb = Self.split(b.hostPort)
            switch pa.host.localizedCaseInsensitiveCompare(pb.host) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                if pa.port != pb.port { return pa.port < pb.port }
                return a.hostPort < b.hostPort
            }
        }
    }

    /// The live key's row (search ignored); nil when missing or removed.
    public func row(_ id: UUID) -> Row? {
        _ = vault.revision
        guard let record = vault.get(KnownHost.self, id: id) else { return nil }
        let parts = Self.split(record.hostPort)
        return Row(id: record.id, hostPort: record.hostPort,
                   address: Self.displayAddress(host: parts.host, port: parts.port),
                   keyType: record.keyType, fingerprint: record.fingerprintSHA256, firstSeen: record.firstSeen,
                   firstSeenText: dateFormatter.string(from: record.firstSeen),
                   usedBy: savedHostsByHostPort()[record.hostPort] ?? [])
    }

    /// Removes these keys (tombstones that sync). Missing, removed or non-key ids are ignored.
    public func remove(_ ids: [UUID]) {
        for id in Set(ids) {
            guard var record = vault.get(KnownHost.self, id: id) else { continue }
            record.deleted = true
            vault.saveNow(record)
        }
    }

    /// Removes every key of `hostPort` (stored form), whether or not the search shows it.
    public func removeAll(hostPort: String) {
        remove(vault.all(KnownHost.self).filter { $0.hostPort == hostPort }.map(\.id))
    }

    // MARK: Helpers

    /// Saved hosts keyed by the host:port the connection checks keys for: the trimmed address
    /// and the effective port (the host's, else its groups', else 22), in `HostKeyFormat.hostPort`
    /// form, as `ConnectionPlanner` and the SSH engines build it.
    private func savedHostsByHostPort() -> [String: [SavedHostRef]] {
        let hosts = vault.all(SavedHost.self)
        let directory = HostDirectory(hosts: hosts, groups: vault.all(HostGroup.self))
        var result: [String: [SavedHostRef]] = [:]
        for host in hosts {
            let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let key = HostKeyFormat.hostPort(host: address, port: directory.effectivePort(for: host))
            let label = host.label.trimmingCharacters(in: .whitespacesAndNewlines)
            result[key, default: []].append(SavedHostRef(id: host.id, label: label.isEmpty ? "Untitled host" : label))
        }
        for (key, refs) in result {
            result[key] = refs.sorted { a, b in
                switch a.label.localizedCaseInsensitiveCompare(b.label) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: a.id.uuidString < b.id.uuidString
                }
            }
        }
        return result
    }

    /// `[host]:port` → (host, port); anything else is a host on port 22.
    nonisolated static func split(_ hostPort: String) -> (host: String, port: Int) {
        if hostPort.hasPrefix("["), let close = hostPort.range(of: "]:", options: .backwards),
           let port = Int(hostPort[close.upperBound...]) {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close.lowerBound])
            return (host, port)
        }
        return (hostPort, 22)
    }

    /// `host`, or `host:port` when the port isn't 22 (`[host]:port` for an IPv6 address).
    nonisolated static func displayAddress(host: String, port: Int) -> String {
        guard port != 22 else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
