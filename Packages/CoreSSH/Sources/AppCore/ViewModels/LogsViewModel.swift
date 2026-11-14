import Foundation
import Observation
import CoreModels

@MainActor @Observable
public final class LogsViewModel {
    public struct Row: Identifiable, Equatable {
        public let id: UUID
        public let dateText: String
        public let timeRangeText: String
        public let deviceName: String
        public let hostLabel: String
        public let username: String
        public let badge: OSBadge?
        public let saved: Bool
    }

    @ObservationIgnored private let vault: LocalVault
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let dateFormatter: DateFormatter
    @ObservationIgnored private let timeFormatter: DateFormatter

    public init(vault: LocalVault, timeZone: TimeZone = .current) {
        self.vault = vault
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = timeZone
            f.dateFormat = format
            return f
        }
        dateFormatter = formatter("MMM dd, yyyy")
        timeFormatter = formatter("HH:mm")
    }

    /// Non-deleted logs, newest first (ties broken by id).
    public var rows: [Row] {
        _ = vault.revision
        return vault.all(ConnectionLog.self)
            .sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString < $1.id.uuidString }
            .map(row(for:))
    }

    public func toggleSaved(id: UUID) {
        guard var log = vault.get(ConnectionLog.self, id: id) else { return }
        log.saved.toggle()
        vault.saveNow(log)
    }

    private func row(for log: ConnectionLog) -> Row {
        Row(id: log.id,
            dateText: dateFormatter.string(from: log.startedAt),
            timeRangeText: timeRange(start: log.startedAt, end: log.endedAt),
            deviceName: log.deviceName,
            hostLabel: log.hostLabel,
            username: log.username,
            badge: log.hostID.flatMap { vault.get(SavedHost.self, id: $0)?.osBadge },
            saved: log.saved)
    }

    private func timeRange(start: Date, end: Date?) -> String {
        let from = timeFormatter.string(from: start)
        guard let end else { return "\(from) - \u{2026}" }
        var text = "\(from) - \(timeFormatter.string(from: end))"
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: end)).day ?? 0
        if days > 0 { text += " (+\(days)d)" }
        return text
    }
}
