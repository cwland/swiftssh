import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import CoreModels

/// Settings → OS Icons: per OS, a live badge preview, an image from a file or a link, a badge
/// color, "Show in white" and Reset. Every change goes through `BadgeLogoStore.shared`, so all
/// badges in the app update at once.
struct OSIconsSettingsPane: View {
    private var store: BadgeLogoStore { .shared }
    @State private var importTarget: OSBadge?
    @State private var isImporting = false
    @State private var linkTarget: BadgeTarget?
    @State private var alertMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OS Icons")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Choose the image and color of each OS badge on host cards, tabs and logs.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    ForEach(BadgeStyle.settingsOrder, id: \.self) { badge in
                        OSIconRow(
                            badge: badge,
                            store: store,
                            chooseImage: {
                                importTarget = badge
                                isImporting = true
                            },
                            fromLink: { linkTarget = BadgeTarget(badge: badge) },
                            reset: {
                                if let message = store.reset(badge) {
                                    alertMessage = message
                                }
                            }
                        )
                    }
                }

                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Picks up logos added to or removed from the folder by hand since launch.
        .onAppear { store.reload() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.imageTypes) { result in
            guard let badge = importTarget else { return }
            importTarget = nil
            switch result {
            case .success(let url):
                importFile(url, for: badge)
            case .failure(let error):
                alertMessage = "Couldn't open that file: \(error.localizedDescription)"
            }
        }
        .sheet(item: $linkTarget) { target in
            ImageLinkSheet(badge: target.badge, store: store)
        }
        .alert("OS Icons", isPresented: Binding(get: { alertMessage != nil },
                                                set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
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

    private func importFile(_ url: URL, for badge: OSBadge) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            alertMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }
        do {
            try store.install(imageData: data, for: badge, notAnImage: .notAnImageFile)
        } catch {
            alertMessage = error.message
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

/// `OSBadge` for `.sheet(item:)` (avoids a retroactive `Identifiable` conformance).
private struct BadgeTarget: Identifiable {
    let badge: OSBadge
    var id: String { badge.rawValue }
}

private struct OSIconRow: View {
    let badge: OSBadge
    let store: BadgeLogoStore
    let chooseImage: () -> Void
    let fromLink: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: Theme.cardPadding) {
            BadgeView(badge: badge, size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
            VStack(alignment: .leading, spacing: 2) {
                Text(BadgeStyle.settingsName(for: badge))
                    .font(.system(size: Theme.cardTitleFontSize))
                    .lineLimit(1)
                Text(store.hasLogo(badge) ? "Custom image" : "Standard symbol")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            Toggle("Show in white", isOn: whiteBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("On: the image is drawn in white. Off: it keeps its own colors.")
            ColorPicker("Badge color", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Badge color")
            Button("Choose Image…", action: chooseImage)
            Button("From URL…", action: fromLink)
            Button("Reset", action: reset)
                .disabled(!store.isCustomized(badge))
                .help("Standard symbol, color and white drawing")
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(height: Theme.cardHeight + 4)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
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

/// From URL…: a link field; downloads, checks and installs the image, with inline errors.
private struct ImageLinkSheet: View {
    let badge: OSBadge
    let store: BadgeLogoStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var download: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BadgeView(badge: badge, size: 32)
                Text("Image for \(BadgeStyle.settingsName(for: badge))")
                    .font(.headline)
            }
            Text("Paste a link to an SVG, PNG, JPEG or PDF image of up to 2 MB.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("https://", text: $link)
                .textFieldStyle(.roundedBorder)
                .disabled(isDownloading)
                .onSubmit(start)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    download?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Download", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDownloading || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: link) {
            errorMessage = nil
        }
        .onDisappear {
            download?.cancel()
        }
    }

    private func start() {
        guard !isDownloading else { return }
        let url: URL
        do {
            url = try BadgeImageRules.webURL(from: link)
        } catch {
            errorMessage = error.message
            return
        }
        errorMessage = nil
        isDownloading = true
        download = Task {
            defer { isDownloading = false }
            do throws(BadgeImageError) {
                let data = try await BadgeImageDownloader.download(from: url)
                guard !Task.isCancelled else { return }
                try store.install(imageData: data, for: badge, notAnImage: .notAnImage)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.message
            }
        }
    }
}
