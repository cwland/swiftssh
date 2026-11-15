import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import CoreModels

/// Settings → OS Icons: the OS catalog grouped by category, each group an adaptive grid of tiles
/// (badge and name). Clicking a tile opens a popup with that OS's settings (`OSIconPopup`). Icons
/// download automatically in the background (see `BadgeLogoStore.startAutomaticDownloads`).
/// Every change goes through `BadgeLogoStore.shared`, so all badges in the app update at once.
struct OSIconsSettingsPane: View {
    private var store: BadgeLogoStore { .shared }
    @State private var importTarget: OSBadge?
    @State private var popupBadge: OSBadge?
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
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)],
                                      alignment: .leading, spacing: 12) {
                                ForEach(category.entries) { entry in
                                    OSIconTile(entry: entry, store: store) { popupBadge = entry.id }
                                        .popover(isPresented: popupBinding(for: entry.id), arrowEdge: .bottom) {
                                            OSIconPopup(
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
                                }
                            }
                            .padding(.bottom, 8)
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

    private func popupBinding(for badge: OSBadge) -> Binding<Bool> {
        Binding(get: { popupBadge == badge },
                set: { if !$0, popupBadge == badge { popupBadge = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OS Icons")
                .font(.system(size: 22, weight: .semibold))
            Text("Choose the image and color of each OS badge on host cards, tabs and logs. Icons download automatically; click an OS to change its icon, link or color.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
