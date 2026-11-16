import SwiftUI
import Foundation
import AppCore
import SyncCore
import SwiftSSHUI

// MARK: - Phase presentation

/// How a sync phase looks: the cloud symbol, its color and a one-line status. Shared by the
/// Vaults tab's cloud icon, its popover and Settings → Sync.
extension SyncCoordinator.Phase {
    /// The top bar's symbol; nil when sync isn't set up (no icon).
    var cloudSymbol: String? {
        switch self {
        case .notConfigured: nil
        case .idle: "icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "icloud.slash"
        case .failed, .needsVault, .locked: "exclamationmark.icloud"
        }
    }

    /// Orange when Cory needs to act (an error, or setup not finished on this Mac).
    var needsAttention: Bool {
        switch self {
        case .failed, .needsVault, .locked: true
        case .notConfigured, .idle, .syncing, .offline: false
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    /// Phases in which "Sync now" makes sense (the server and the vault key are set up).
    var canSyncNow: Bool {
        switch self {
        case .idle, .offline, .failed: true
        case .notConfigured, .needsVault, .locked, .syncing: false
        }
    }

    /// The status line. `.idle` uses `lastSyncedAt` ("Synced 2 minutes ago").
    func statusText(lastSyncedAt: Date?, now: Date) -> String {
        switch self {
        case .notConfigured: "Sync is not set up"
        case .needsVault(exists: false): "Create the vault to start syncing"
        case .needsVault(exists: true): "Join the vault to start syncing"
        case .locked: "Enter the sync passphrase on this Mac"
        case .idle: SyncTime.syncedText(lastSyncedAt, now: now)
        case .syncing: "Syncing\u{2026}"
        case .offline: "Offline \u{2014} retrying"
        case .failed(let message): message
        }
    }

    /// Extra detail under the status line: why the server can't be reached.
    var detailText: String? {
        if case .offline(let message) = self, !message.isEmpty { return message }
        return nil
    }
}

enum SyncTime {
    /// "Synced just now", "Synced 2 minutes ago"; "Not synced yet" without a date.
    static func syncedText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not synced yet" }
        return "Synced \(relative(date, now: now))"
    }

    /// "just now" under a minute, otherwise "2 minutes ago".
    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Sent 3 · Received 5".
    static func reportText(_ report: SyncReport) -> String {
        "Sent \(report.pushed) \u{00B7} Received \(report.pulled)"
    }
}

/// The phase's symbol, spinning while syncing (still when Reduce Motion is on).
struct SyncPhaseIcon: View {
    let phase: SyncCoordinator.Phase
    var size: CGFloat = 12
    /// The color for phases that don't need attention.
    var normalColor: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if phase.isSyncing && !reduceMotion {
            TimelineView(.animation) { context in
                image.rotationEffect(.degrees(Self.angle(at: context.date)))
            }
        } else {
            image
        }
    }

    /// Settings shows a symbol even before sync is set up.
    private var symbol: String { phase.cloudSymbol ?? "icloud.slash" }

    private var image: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(phase.needsAttention ? Theme.warningForeground : normalColor)
    }

    /// One turn every 1.2 seconds.
    private static func angle(at date: Date) -> Double {
        let period = 1.2
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period * 360
    }
}

/// The status line with its icon, refreshed every 30 seconds so "2 minutes ago" stays current.
struct SyncStatusLine: View {
    let sync: SyncCoordinator
    var fontSize: CGFloat = 13

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SyncPhaseIcon(phase: sync.phase, size: fontSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.phase.statusText(lastSyncedAt: sync.lastSyncedAt, now: context.date))
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(sync.phase.needsAttention ? Theme.warningForeground : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = sync.phase.detailText {
                        Text(detail)
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Top bar

/// The Vaults tab's cloud icon. Hidden while sync isn't set up; a click shows `SyncStatusPopover`.
struct SyncCloudButton: View {
    let sync: SyncCoordinator

    @State private var isShowingPopover = false
    @Environment(SettingsNavigation.self) private var settingsNavigation: SettingsNavigation?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if sync.phase.cloudSymbol != nil {
            Button {
                isShowingPopover.toggle()
            } label: {
                SyncPhaseIcon(phase: sync.phase, size: 12, normalColor: Theme.topBarForeground)
                    .opacity(sync.phase.needsAttention ? 1 : 0.8)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sync.phase.statusText(lastSyncedAt: sync.lastSyncedAt, now: Date()))
            .accessibilityLabel("Sync status")
            .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                SyncStatusPopover(sync: sync) {
                    isShowingPopover = false
                    settingsNavigation?.selection = .sync
                    openSettings()
                }
            }
        }
    }
}

/// Status, last sync, the last sync's counts, "Sync now" and "Sync settings…".
struct SyncStatusPopover: View {
    let sync: SyncCoordinator
    let openSyncSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SyncStatusLine(sync: sync)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastSyncedText(now: context.date))
                    if let report = sync.lastReport {
                        Text("Last sync: \(SyncTime.reportText(report))")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Sync now") {
                    Task { await sync.syncNow() }
                }
                .disabled(!sync.phase.canSyncNow)
                Spacer(minLength: 12)
                Button("Sync settings\u{2026}", action: openSyncSettings)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func lastSyncedText(now: Date) -> String {
        guard let date = sync.lastSyncedAt else { return "Last synced: never" }
        return "Last synced: \(SyncTime.relative(date, now: now))"
    }
}
