import SwiftUI
import AppCore
import CoreModels

/// The popup for one OS: icon link (editing saves and downloads at once), Download, Choose Image…,
/// Show in white, badge color and Reset. All changes go through `BadgeLogoStore`, so every badge
/// in the app updates at once.
struct OSIconPopup: View {
    let entry: OSCatalog.Entry
    let store: BadgeLogoStore
    let chooseImage: () -> Void
    let reset: () -> Void
    @State private var draft = ""
    @FocusState private var linkFocused: Bool

    private var badge: OSBadge { entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Theme.cardPadding) {
                BadgeView(badge: badge, size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: Theme.cardTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Icon link", text: $draft, prompt: Text("https://"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($linkFocused)
                        .onSubmit(commitLink)
                        .help("Editing the link saves it and downloads the image right away")
                    Button("Download", action: download)
                        .disabled(store.isWorking(badge) || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if case .working(let label) = store.status(for: badge) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if case .failed(let message) = store.status(for: badge) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Choose Image…", action: chooseImage)
                    .disabled(store.isWorking(badge))
                Spacer(minLength: 0)
            }

            Divider()

            HStack {
                Toggle("Show in white", isOn: whiteBinding)
                    .toggleStyle(.switch)
                    .disabled(!store.hasLogo(badge))
                    .help(store.hasLogo(badge)
                          ? "On: the image is drawn in white. Off: it keeps its own colors."
                          : "Available once this OS has an image. The standard symbol is always white.")
                Spacer(minLength: 8)
                Text("Badge color")
                    .font(.system(size: 13))
                ColorPicker("Badge color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }

            HStack {
                Spacer(minLength: 0)
                Button("Reset to Default", action: resetRow)
                    .disabled(!store.isCustomized(badge) && store.status(for: badge) == nil)
                    .help("Standard symbol, color, white drawing and default link")
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { draft = store.link(for: badge) }
        .onChange(of: store.link(for: badge)) { _, link in
            // Reset, or a link saved elsewhere; never while the user is typing.
            if !linkFocused { draft = link }
        }
        .onChange(of: linkFocused) { _, isFocused in
            if !isFocused { commitLink() }
        }
        .onChange(of: draft) {
            // Typing clears the error; programmatic updates (appear, Reset) keep it.
            if linkFocused { store.clearError(for: badge) }
        }
    }

    private var subtitle: String {
        guard store.hasLogo(badge) else { return "Standard symbol" }
        if let source = store.imageSource(for: badge) {
            return "Downloaded from \(source)"
        }
        return "Custom image"
    }

    private func resetRow() {
        reset()
        draft = store.link(for: badge)
    }

    private func commitLink() {
        store.commitLink(draft, for: badge)
    }

    /// An edited link is saved first (which downloads it); otherwise the current link is fetched.
    private func download() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != store.link(for: badge) {
            store.commitLink(trimmed, for: badge)
        } else {
            store.download(badge)
        }
    }

    private var whiteBinding: Binding<Bool> {
        Binding(get: { store.showsInWhite(for: badge) },
                set: { store.setShowsInWhite($0, for: badge) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: store.hexColor(for: badge)) },
                set: { color in
                    if let hex = color.sRGBHex {
                        store.setColor(hex, for: badge)
                    }
                })
    }
}
