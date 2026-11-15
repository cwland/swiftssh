import SwiftUI
import AppCore

/// Settings → Connection: reconnecting, how quickly a dropped connection is noticed (one radio row per
/// `DroppedConnectionDetection` case, applied to sessions opened afterwards), and whether closing an
/// unsaved workspace asks to save it. Saved by `ConnectionSettings`, on this Mac only.
struct ConnectionSettingsPane: View {
    let settings: ConnectionSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection")
                    .font(.system(size: 22, weight: .semibold))

                Toggle(isOn: Binding(get: { settings.autoReconnect },
                                     set: { settings.autoReconnect = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reconnect automatically")
                            .font(.system(size: Theme.cardTitleFontSize))
                        Text("When a connection drops, try again after 5 seconds, then 10, 20 and 30 \u{2014} up to 5 tries.")
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Text("Detect dropped connections")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(DroppedConnectionDetection.allCases, id: \.self) { option in
                        DetectionRow(option: option, isSelected: settings.detection == option) {
                            settings.detection = option
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Detect dropped connections")

                Text("Applies to sessions you open from now on. Open tabs keep their current setting. Saved on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 4)

                Text("Workspaces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(get: { settings.askToSaveWorkspaces },
                                     set: { settings.askToSaveWorkspaces = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask to save workspaces when closing")
                            .font(.system(size: Theme.cardTitleFontSize))
                        Text("Closing a split view workspace with unsaved changes asks whether to save it first.")
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct DetectionRow: View {
    let option: DroppedConnectionDetection
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Theme.cardPadding) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: Theme.cardTitleFontSize))
                        .foregroundStyle(Color.primary)
                    Text(option.detail)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
