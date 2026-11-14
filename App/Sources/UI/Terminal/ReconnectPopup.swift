import SwiftUI
import AppCore

/// The card over the top-left of a terminal whose connection dropped and is being re-opened
/// automatically: a countdown ring, how many sessions are waiting, Reconnect (Return) and
/// Close terminal. The × stops the countdown and leaves the disconnected banner.
///
/// It exists only while the tab's `autoReconnect` is `.waiting` or `.reconnecting`, so its Return
/// shortcut cannot take Return from the terminal at any other time.
struct ReconnectPopup: View {
    let state: AutoReconnectState
    /// Sessions counting down or reconnecting (`SessionManager.waitingForReconnectCount`).
    let sessionCount: Int
    let reconnectNow: () -> Void
    let closeTerminal: () -> Void
    let dismiss: () -> Void

    private static let ringColor = Color(hex: "#F5C542")

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            indicator
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionCount == 1 ? "1 session is disconnected."
                                           : "\(max(sessionCount, 1)) sessions are disconnected.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                HStack(spacing: 8) {
                    Button(action: reconnectNow) {
                        Text("Reconnect \u{21B5}")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityLabel("Reconnect now")

                    Button(action: closeTerminal) {
                        Text("Close terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop reconnecting")
            .accessibilityLabel("Stop reconnecting")
        }
        .padding(14)
        .background(Color(hex: "#2A2D3E").opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        switch state {
        case .waiting: "Initiating reconnection\u{2026}"
        case .reconnecting: "Reconnecting\u{2026}"
        case .gaveUp: "Couldn\u{2019}t reconnect."
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .waiting(_, let deadline, let delay):
            CountdownRing(deadline: deadline, delay: delay, color: Self.ringColor)
        case .reconnecting, .gaveUp:
            ProgressView()
                .controlSize(.small)
                .colorScheme(.dark)
        }
    }
}

/// A ring that empties as `deadline` approaches, with the remaining whole seconds in the middle.
private struct CountdownRing: View {
    let deadline: Date
    let delay: TimeInterval
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let fraction = delay > 0 ? min(1, remaining / delay) : 0
            ZStack {
                Circle()
                    .stroke(color.opacity(0.22), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reconnecting soon")
    }
}
