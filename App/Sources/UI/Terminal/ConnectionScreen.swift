import SwiftUI
import AppKit
import AppCore
import CoreModels

/// The full-tab screen shown while a tab connects and when its first connection fails: the host,
/// a progress line from host to terminal, the step-by-step log and Close / Edit host / Start over.
/// Colors follow the tab's terminal theme (`appearance`), like the terminal behind it.
/// The log lines come from `tab.connectionLog`; their text is already user-facing and secret-free.
struct ConnectionScreen: View {
    let tab: TerminalTab
    let vault: LocalVault
    let appearance: TerminalAppearance
    /// nil hides the button (quick connect, or a window without Vaults).
    let editHost: (() -> Void)?
    let startOver: () -> Void
    let close: () -> Void

    @State private var didCopy = false

    private enum Phase { case connecting, connected, failed }

    private var phase: Phase {
        switch tab.state {
        case .connected: .connected
        case .disconnected: .failed
        case .connecting, .awaitingHostKey, .awaitingPassword: .connecting
        }
    }

    private var foreground: Color { appearance.theme.foreground.swiftUIColor }
    private var secondary: Color { foreground.opacity(0.6) }
    private var failureColor: Color { Color(red: 0.94, green: 0.33, blue: 0.31) }

    /// The saved host, nil for quick connect (or a host deleted meanwhile).
    private var host: SavedHost? {
        _ = vault.revision
        return tab.savedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
    }

    private var endpointText: String {
        guard let host else { return "SSH \(tab.title)" }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        var text = "SSH \(host.address):\(directory.effectivePort(for: host))"
        if let user = host.username, !user.isEmpty { text += " (\(user))" }
        return text
    }

    /// Shown under the log when the attempt ended without the log saying why.
    private var failureText: String? {
        guard phase == .failed else { return nil }
        if let text = tab.connectionFailure { return text }
        if case .disconnected(let message) = tab.state { return message ?? "Connection closed" }
        return nil
    }

    var body: some View {
        VStack(spacing: 28) {
            header
            progressLine
            stepList
            buttons
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.theme.background.swiftUIColor)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            BadgeView(badge: host?.osBadge ?? tab.badge, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(host?.label ?? tab.displayTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Text(endpointText)
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: copyLogs) {
                Label(didCopy ? "Copied" : "Copy logs", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ConnectionScreenButtonStyle(foreground: foreground))
            .help("Copy the connection log")
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

    // MARK: Progress line

    private var lineColor: Color {
        switch phase {
        case .failed: failureColor
        case .connected, .connecting: Theme.accent
        }
    }

    private var progressLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(secondary)
            ProgressTrack(phase: phase == .connecting ? .animating : .solid,
                          color: lineColor, track: foreground.opacity(0.15))
                .frame(height: 4)
            Image(systemName: phase == .failed ? "xmark.circle.fill" : "terminal")
                .font(.system(size: 20))
                .foregroundStyle(phase == .failed ? failureColor : secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .failed ? "Connection failed" : phase == .connected ? "Connected" : "Connecting")
    }

    // MARK: Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tab.connectionLog.isEmpty, phase != .failed {
                // No progress from the engine (yet): the plain state.
                StepRow(icon: .spinner, text: "Connecting\u{2026}", time: nil,
                        foreground: foreground, secondary: secondary, failure: failureColor)
            }
            ForEach(tab.connectionLog) { line in
                StepRow(icon: icon(for: line.status), text: line.text,
                        time: relativeTime(line.at),
                        foreground: line.status == .failed ? failureColor : foreground,
                        secondary: secondary, failure: failureColor)
            }
            if let failureText, tab.connectionLog.last?.status != .failed {
                StepRow(icon: .failed, text: failureText, time: nil,
                        foreground: failureColor, secondary: secondary, failure: failureColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func icon(for status: ConnectionLogLine.Status) -> StepRow.Icon {
        switch status {
        case .inProgress: .spinner
        case .done: .done
        case .failed: .failed
        }
    }

    /// Seconds since the attempt's first line, "+0.4s".
    private func relativeTime(_ date: Date) -> String? {
        guard let first = tab.connectionLog.first?.at else { return nil }
        let seconds = max(0, date.timeIntervalSince(first))
        return String(format: "+%.1fs", seconds)
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Close", action: close)
                .buttonStyle(ConnectionScreenButtonStyle(foreground: foreground))
            if let editHost, host != nil {
                Button("Edit host", action: editHost)
                    .buttonStyle(ConnectionScreenButtonStyle(foreground: foreground))
            }
            if phase == .failed {
                Button("Start over", action: startOver)
                    .buttonStyle(ConnectionScreenButtonStyle(foreground: foreground, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// One line of the log: spinner, check or cross, the text and its relative time.
private struct StepRow: View {
    enum Icon { case spinner, done, failed }

    let icon: Icon
    let text: String
    let time: String?
    let foreground: Color
    let secondary: Color
    let failure: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            iconView
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let time {
                Text(time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondary)
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .spinner:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(failure)
        }
    }
}

/// The line between the host and the terminal: a bar sweeping left to right while connecting,
/// solid once the attempt ended (green-blue accent when connected, red on failure).
private struct ProgressTrack: View {
    enum Mode { case animating, solid }

    let phase: Mode
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                switch phase {
                case .solid:
                    Capsule().fill(color)
                case .animating:
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let progress = (t / 1.4).truncatingRemainder(dividingBy: 1)
                        let width = proxy.size.width * 0.3
                        Capsule()
                            .fill(color)
                            .frame(width: width)
                            .offset(x: (proxy.size.width + width) * progress - width)
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}

/// Rounded buttons in the theme's foreground color, readable on any terminal background.
private struct ConnectionScreenButtonStyle: ButtonStyle {
    let foreground: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.accent : foreground.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
