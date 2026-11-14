import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import CoreModels

/// Settings → OS Icons: the OS catalog grouped by category. Each row has a live badge preview, the
/// icon link (prefilled with the catalog default; editing it saves it and downloads it at once),
/// Download, Choose Image…, Reset, Show in white and the badge color. Download All Defaults fetches
/// every default icon an entry doesn't already have. Nothing downloads without one of these actions.
/// Every change goes through `BadgeLogoStore.shared`, so all badges in the app update at once.
struct OSIconsSettingsPane: View {
    private var store: BadgeLogoStore { .shared }
    @State private var importTarget: OSBadge?
    @State private var isImporting = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.catalog.categories) { category in
                        Section {
                            ForEach(category.entries) { entry in
                                OSIconRow(
                                    entry: entry,
                                    store: store,
                                    chooseImage: {
                                        importTarget = entry.id
                                        isImporting = true
                                    },
                                    reset: {
                                        if let message = store.reset(entry.id) {
                                            alertMessage = message
                                        }
                                    }
                                )
                            }
                        } header: {
                            Text(category.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .background(Theme.contentBackground)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Picks up logos added to or removed from the folder by hand since launch.
        .onAppear { store.reload() }
        .onDisappear { store.flushPendingSave() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.imageTypes) { result in
            guard let badge = importTarget else { return }
            importTarget = nil
            switch result {
            case .success(let url):
                store.installFile(at: url, for: badge)
            case .failure(let error):
                alertMessage = "Couldn't open that file: \(error.localizedDescription)"
            }
        }
        .alert("OS Icons", isPresented: Binding(get: { alertMessage != nil },
                                                set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OS Icons")
                    .font(.system(size: 22, weight: .semibold))
                Text("Choose the image and color of each OS badge on host cards, tabs and logs. Icons download only when you ask.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = store.batchMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let batch = store.batch {
                HStack(spacing: 8) {
                    ProgressView(value: Double(batch.finished), total: Double(max(batch.total, 1)))
                        .frame(width: 140)
                    Text("\(batch.finished) of \(batch.total)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Stop") { store.cancelBatch() }
                }
            } else {
                Button("Download All Defaults") { store.downloadAllDefaults() }
                    .help("Downloads the default icon of every OS that has no image of its own yet")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.settingsSaveError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Images are stored on this Mac only, in Application Support/TermiusReimagined/Badges.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let directory = store.directory {
                    Button("Show in Finder") {
                        BadgeLogoStore.createDirectoryIfNeeded()
                        NSWorkspace.shared.open(directory)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// svg, png, jpeg and pdf.
    private static let imageTypes: [UTType] = {
        var types: [UTType] = []
        for fileExtension in BadgeImageRules.allowedFileExtensions {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()
}

private struct OSIconRow: View {
    let entry: OSCatalog.Entry
    let store: BadgeLogoStore
    let chooseImage: () -> Void
    let reset: () -> Void
    @State private var draft = ""
    @FocusState private var linkFocused: Bool

    private var badge: OSBadge { entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.cardPadding) {
                BadgeView(badge: badge, size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: Theme.cardTitleFontSize))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
                .frame(minWidth: 160, alignment: .leading)

                Spacer(minLength: 8)

                Toggle("Show in white", isOn: whiteBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!store.hasLogo(badge))
                    .help(store.hasLogo(badge)
                          ? "On: the image is drawn in white. Off: it keeps its own colors."
                          : "Available once this OS has an image. The standard symbol is always white.")
                ColorPicker("Badge color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help("Badge color")
                Button("Choose Image…", action: chooseImage)
                    .disabled(store.isWorking(badge))
                Button("Reset", action: reset)
                    .disabled(!store.isCustomized(badge) && store.status(for: badge) == nil)
                    .help("Standard symbol, color, white drawing and default link")
            }

            HStack(spacing: 8) {
                TextField("Icon link", text: $draft, prompt: Text("https://"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($linkFocused)
                    .onSubmit(commitLink)
                    .help("Editing the link saves it and downloads the image right away")
                if case .working(let label) = store.status(for: badge) {
                    ProgressView()
                        .controlSize(.small)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button("Download", action: download)
                    .disabled(store.isWorking(badge) || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if case .failed(let message) = store.status(for: badge) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.cardPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .onAppear {
            draft = store.link(for: badge)
        }
        .onChange(of: store.link(for: badge)) { _, link in
            // Reset, or a link saved elsewhere; never while the user is typing.
            if !linkFocused { draft = link }
        }
        .onChange(of: linkFocused) { _, isFocused in
            if !isFocused { commitLink() }
        }
        .onChange(of: draft) {
            // Typing clears the row's error; programmatic updates (appear, Reset) keep it.
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

    /// Saves and downloads an edited link; an unchanged link does nothing.
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
