import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import CoreModels
import SwiftSSHUI

/// Settings → OS Icons: the OS catalog grouped by category, each group an adaptive grid of tiles
/// (badge and name). Clicking a tile opens a sheet with that OS's settings (`OSIconPopup`). Icons
/// download automatically in the background (see `BadgeLogoStore.startAutomaticDownloads`).
/// Every change goes through `BadgeLogoStore.shared`, so all badges in the app update at once.
struct OSIconsSettingsPane: View {
    private var store: BadgeLogoStore { .shared }
    @State private var sheetEntry: OSCatalog.Entry?

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
                                    OSIconTile(entry: entry, store: store) { sheetEntry = entry }
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
        .sheet(item: $sheetEntry) { entry in
            OSIconPopup(entry: entry, store: store) { sheetEntry = nil }
        }
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
                Text("Images are stored on this Mac only, in Application Support/SwiftSSH/Badges.")
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
}
