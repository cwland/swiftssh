import SwiftUI
import AppKit
import AppCore
import CoreModels
import SSHCore
import SwiftSSHUI

/// The full-tab screen shown while a tab connects, while it reconnects on its own, and when a try fails,
/// modelled on Termius's: on the app's own light/dark background, a narrow column near the top with
/// the host (badge, name, "SSH address:port"), a line from a plug to the terminal (a spinning ring and
/// a growing blue line while connecting; all red on failure; all blue once connected, then the screen
/// fades into the terminal), and, on failure, "Connection failed with connection log:" with the log
/// card and Close / Edit host / Start over. While connecting, "Show logs" opens the log card.
/// The log lines come from `tab.connectionLog`; their text is already user-facing and secret-free.
struct ConnectionScreen: View {
    let tab: TerminalTab
    let vault: LocalVault
    /// The terminal's look; kept for callers (the screen follows the app's own colours, as in Termius).
    let appearance: TerminalAppearance
    /// nil hides the button (quick connect, or a window without Vaults).
    let editHost: (() -> Void)?
    let startOver: () -> Void
    let close: () -> Void

    @State private var showsLogWhileConnecting = false
    @State private var didCopy = false

    enum Phase: Equatable { case connecting, connected, failed }

    private var phase: Phase {
        switch tab.state {
        case .connected: .connected
        case .disconnected: .failed
        case .connecting, .awaitingHostKey, .awaitingPassword: .connecting
        }
    }

    static let accent = Color(red: 0.22, green: 0.55, blue: 0.96)
    static let failure = Color(red: 0.93, green: 0.30, blue: 0.29)
    /// The line and the terminal circle before they light up.
    static let idle = Color(red: 0.33, green: 0.35, blue: 0.42)

    /// The saved host, nil for quick connect (or a host deleted meanwhile).
    private var host: SavedHost? {
        _ = vault.revision
        return tab.savedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
    }

    private var endpointText: String {
        guard let host else { return "SSH \(tab.title)" }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        // The address this attempt uses: the backup address once the main one couldn't be reached.
        let address = tab.currentAddress ?? host.address
        let backup = tab.isUsingBackupAddress ? " (backup address)" : ""
        return "SSH \(address):\(directory.effectivePort(for: host))\(backup)"
    }

    /// Shown as the log's last line when the attempt ended without the log saying why.
    private var failureText: String? {
        guard phase == .failed else { return nil }
        if let text = tab.connectionFailure { return text }
        if case .disconnected(let message) = tab.state { return message ?? "Connection closed" }
        return nil
    }

    private var showsLog: Bool { phase == .failed || showsLogWhileConnecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ConnectionLine(phase: phase, progress: progress)
                .padding(.top, 14)
            if phase == .failed {
                Text("Connection failed with connection log:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.failure)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
                    .transition(.opacity)
            }
            if showsLog {
                logCard
                    .padding(.top, phase == .failed ? 10 : 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            buttons
                .padding(.top, 18)
        }
        .frame(width: 320)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBackground)
        .animation(.easeInOut(duration: 0.3), value: phase)
        .animation(.easeInOut(duration: 0.25), value: showsLog)
        .onChange(of: phase) { if phase == .connecting { showsLogWhileConnecting = false } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BadgeView(badge: host?.osBadge ?? tab.badge, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(host?.label ?? tab.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(endpointText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if phase == .failed {
                Button(didCopy ? "Copied" : "Copy logs", action: copyLogs)
                    .buttonStyle(PillButtonStyle())
                    .help("Copy the connection log")
            } else {
                Button(showsLogWhileConnecting ? "Hide logs" : "Show logs") {
                    showsLogWhileConnecting.toggle()
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tab.connectionLogText(), forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    /// How much of the line is blue while connecting: a little at first, more with each finished step.
    private var progress: Double {
        switch phase {
        case .connected, .failed: return 1
        case .connecting:
            let done = tab.connectionLog.filter { $0.status == .done }.count
            return min(0.12 + Double(done) * 0.13, 0.9)
        }
    }

    // MARK: Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if tab.connectionLog.isEmpty, phase != .failed {
                            LogRow(symbol: "gearshape", text: "Starting connection\u{2026}", isFailure: false)
                        }
                        ForEach(tab.connectionLog) { line in
                            LogRow(symbol: Self.symbol(for: line), text: line.text, isFailure: line.status == .failed)
                                .id(line.id)
                        }
                        if let failureText, tab.connectionLog.last?.status != .failed {
                            LogRow(symbol: "exclamationmark.triangle.fill", text: failureText, isFailure: true)
                                .id(-1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 220)
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: tab.connectionLog.count) { scrollToEnd(proxy) }
            }
            if phase == .failed {
                Divider()
                    .padding(.horizontal, 16)
                Text("Check the address, port and login with Edit host, or copy the log to look into it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground)
        )
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let last = failureText != nil && tab.connectionLog.last?.status != .failed ? -1 : tab.connectionLog.last?.id
        if let last { proxy.scrollTo(last, anchor: .bottom) }
    }

    /// Termius-like icons per step: gears for network steps, a person once connected, a key for
    /// signing in, a terminal for the shell; a warning for a failed line.
    private static func symbol(for line: ConnectionLogLine) -> String {
        if line.status == .failed { return "exclamationmark.triangle.fill" }
        switch line.step {
        case .resolving, .connecting, .handshake: return "gearshape"
        case .connected: return "person.fill"
        case .authenticating, .authenticated: return "key.fill"
        case .openingShell, .attachingTmux: return "terminal"
        case nil: return "info.circle"
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Close", action: close)
                .buttonStyle(PillButtonStyle())
            if phase == .failed {
                if let editHost, host != nil {
                    Button("Edit host", action: editHost)
                        .buttonStyle(PillButtonStyle())
                }
                if tab.suggestedAction == .openOnePasswordSetup {
                    OpenOnePasswordSetupButton()
                } else if tab.suggestedAction == .chooseOnePasswordVaults {
                    ChooseVaultsButton()
                }
                Spacer(minLength: 8)
                Button("Start over", action: startOver)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// One log line: a small grey (or red) icon and the text.
private struct LogRow: View {
    let symbol: String
    let text: String
    let isFailure: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isFailure ? ConnectionScreen.failure : Color.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isFailure ? ConnectionScreen.failure : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The line from the plug (the Mac) to the terminal. Connecting: a blue ring spins around the plug and
/// the blue part of the line grows with the steps. Failed: the line and both ends turn red. Connected:
/// all blue.
private struct ConnectionLine: View {
    let phase: ConnectionScreen.Phase
    /// 0…1, how much of the line is lit.
    let progress: Double

    private var lit: Color { phase == .failed ? ConnectionScreen.failure : ConnectionScreen.accent }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(lit)
                    .frame(width: 18, height: 18)
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .rotationEffect(.degrees(45))
                if phase == .connecting {
                    SpinningRing(color: ConnectionScreen.accent)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 28, height: 28)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ConnectionScreen.idle)
                    Capsule()
                        .fill(lit)
                        .frame(width: proxy.size.width * progress)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 28)
            .padding(.horizontal, -3)
            ZStack {
                Circle()
                    .fill(phase == .connecting ? ConnectionScreen.idle : lit)
                Text(">_")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 18, height: 18)
        }
        .animation(.easeInOut(duration: 0.4), value: progress)
        .animation(.easeInOut(duration: 0.3), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .failed ? "Connection failed" : phase == .connected ? "Connected" : "Connecting")
    }
}

/// An open blue arc going round, like Termius's.
private struct SpinningRing: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
    }
}

/// Termius-style rounded grey buttons; the prominent one is blue.
private struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? ConnectionScreen.accent : Color.primary.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
