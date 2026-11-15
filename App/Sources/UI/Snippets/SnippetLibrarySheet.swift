import SwiftUI
import AppCore

/// "New Snippet from Library…": ready-made admin snippets by category. Check the ones you want and
/// click Add to Snippets; each becomes an ordinary snippet in a package named after its category.
/// Ones you already have (same command) show "Added". A category's box checks all of its visible ones.
struct SnippetLibrarySheet: View {
    let vault: LocalVault
    /// Called with how many were created (at least one).
    let onAdded: (Int) -> Void
    let onCancel: () -> Void

    @State private var model: SnippetLibraryViewModel?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snippet Library")
                    .font(.system(size: 17, weight: .semibold))
                Text("Common commands for looking after Linux servers. Pick the ones you want; they become regular snippets you can edit. Values in {{braces}} are asked for when you run them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                searchField
                    .padding(.top, 6)
            }
            .padding(20)
            Divider()
            list
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 640, height: 620)
        .onAppear {
            if model == nil { model = SnippetLibraryViewModel(vault: vault) }
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the library", text: Binding(get: { model?.searchText ?? "" },
                                                          set: { model?.searchText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.searchFieldBackground)
        }
    }

    @ViewBuilder
    private var list: some View {
        if let model {
            let sections = model.sections
            if sections.isEmpty {
                Text("Nothing in the library matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.entries) { entry in
                                    LibraryRow(entry: entry, isAdded: model.isAdded(entry),
                                               isSelected: model.isSelected(entry),
                                               toggle: { model.toggle(entry) })
                                }
                            } header: {
                                categoryHeader(section.category, model: model)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        } else {
            Spacer()
        }
    }

    private func categoryHeader(_ category: String, model: SnippetLibraryViewModel) -> some View {
        let state = model.categoryState(category)
        let canCheck = model.hasAddable(in: category)
        return HStack(spacing: 8) {
            Button {
                model.setCategory(category, selected: state != .all)
            } label: {
                Image(systemName: state == .all ? "checkmark.square.fill"
                      : state == .some ? "minus.square.fill" : "square")
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canCheck)
            .opacity(canCheck ? 1 : 0.35)
            .help(!canCheck ? "You already have everything in \(category)."
                  : state == .all ? "Uncheck all in \(category)" : "Check all in \(category)")
            .accessibilityLabel(state == .all ? "Uncheck all in \(category)" : "Check all in \(category)")
            Text(category)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.contentBackground)
    }

    private var footer: some View {
        HStack {
            if let count = model?.selectedCount, count > 0 {
                Text(count == 1 ? "1 selected" : "\(count) selected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Add to Snippets") {
                guard let model else { return }
                let created = model.addSelected()
                if created > 0 { onAdded(created) } else { onCancel() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled((model?.selectedCount ?? 0) == 0)
        }
    }
}

/// One library entry: a check box, its name and description, and the command.
private struct LibraryRow: View {
    let entry: SnippetLibrary.Entry
    let isAdded: Bool
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isAdded ? "checkmark.circle.fill" : isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isAdded ? Color.secondary : isSelected ? Color.accentColor : Color.secondary)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                    if isAdded {
                        Text("Added")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(entry.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(entry.script)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .opacity(isAdded ? 0.6 : 1)
        .onTapGesture { if !isAdded { toggle() } }
        .help(isAdded ? "You already have this snippet." : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { if !isAdded { toggle() } }
    }
}
