import SwiftUI
import AppCore

/// "Pick from 1Password…": search the items `op` lists, choose one, then choose a field; the
/// field's `op://…` reference is handed back. Only titles, vaults and categories are fetched here
/// (`listItems`), never a secret value: the fields offered are the item category's standard fields,
/// built from the chosen summary with `OnePasswordField.standardFields` (no `op` call, no cache on the
/// client), and the password is read with `op read` each time a session connects.
struct OnePasswordItemPicker: View {
    /// nil when `op` wasn't found.
    let client: (any OnePasswordCLI)?
    let choose: (String) -> Void
    let cancel: () -> Void

    private enum Load<Value> {
        case loading
        case loaded(Value)
        case failed(OnePasswordError)
    }

    @State private var items: Load<[OnePasswordItemSummary]> = .loading
    @State private var query = ""
    @State private var selectedItem: OnePasswordItemSummary?
    @State private var itemsAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 480)
        .task(id: itemsAttempt) { await loadItems() }
    }

    // MARK: Layout

    private var header: some View {
        HStack(spacing: 8) {
            if let item = selectedItem {
                Button {
                    selectedItem = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to items")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? "Untitled item" : item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("Choose the field to use")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                Text("Pick from 1Password")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                TextField("Search", text: $query, prompt: Text("Search items"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if client == nil {
            failure(.cliNotFound, retry: nil)
        } else if let item = selectedItem {
            fieldList(item)
        } else {
            switch items {
            case .loading:
                waiting("Asking 1Password for your items\u{2026}")
            case .failed(let error):
                failure(error) { itemsAttempt += 1 }
            case .loaded(let all):
                itemList(all)
            }
        }
    }

    private func itemList(_ all: [OnePasswordItemSummary]) -> some View {
        let matches = filtered(all)
        return Group {
            if all.isEmpty {
                message("No items in 1Password.")
            } else if matches.isEmpty {
                message("No match")
            } else {
                List(matches) { item in
                    Button {
                        select(item)
                    } label: {
                        row(title: item.title.isEmpty ? "Untitled item" : item.title,
                            subtitle: "\(item.vault) \u{00B7} \(Self.categoryName(item.category))",
                            symbol: Self.symbol(for: item.category))
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func fieldList(_ item: OnePasswordItemSummary) -> some View {
        let all = Self.fields(of: item)
        if all.isEmpty {
            message("This item has no fields to use.")
        } else {
            List(Self.ordered(all)) { field in
                Button {
                    choose(field.reference)
                } label: {
                    row(title: field.label.isEmpty ? field.id : field.label,
                        subtitle: field.isSecret ? "Concealed" : "Text",
                        symbol: field.isSecret ? "lock" : "textformat")
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func row(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("1Password may ask you to unlock or use Touch ID.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(24)
    }

    private func failure(_ error: OnePasswordError, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.warningForeground)
            Text(error.message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let retry {
                    Button("Try Again", action: retry)
                }
                if Self.needsSetup(error) {
                    OpenOnePasswordSetupButton(before: cancel)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
    }

    // MARK: Loading

    private func loadItems() async {
        guard let client else { return }
        items = .loading
        do throws(OnePasswordError) {
            let loaded = try await client.listItems()
            items = .loaded(loaded.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            })
        } catch {
            // A sheet closed while waiting cancels the task; nothing to show then.
            guard !Task.isCancelled else { return }
            items = .failed(error)
        }
    }

    private func select(_ item: OnePasswordItemSummary) {
        selectedItem = item
    }

    /// The chosen item's standard fields, from its own summary (category and vault ID included).
    private static func fields(of item: OnePasswordItemSummary) -> [OnePasswordField] {
        OnePasswordField.standardFields(itemID: item.id, vault: item.vault, vaultID: item.vaultID,
                                        category: item.category)
    }

    // MARK: Helpers

    private func filtered(_ all: [OnePasswordItemSummary]) -> [OnePasswordItemSummary] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return all }
        return all.filter {
            $0.title.localizedStandardContains(text) || $0.vault.localizedStandardContains(text)
                || Self.categoryName($0.category).localizedStandardContains(text)
        }
    }

    /// Concealed fields (passwords, keys) first, then the rest; each group keeps 1Password's order.
    private static func ordered(_ fields: [OnePasswordField]) -> [OnePasswordField] {
        fields.filter(\.isSecret) + fields.filter { !$0.isSecret }
    }

    /// The errors whose fix is in Settings → 1Password.
    private static func needsSetup(_ error: OnePasswordError) -> Bool {
        switch error {
        case .cliNotFound, .integrationOff, .appLocked: true
        case .cancelled, .timedOut, .notFound, .failed: false
        }
    }

    /// "SSH_KEY" → "SSH Key", "LOGIN" → "Login".
    static func categoryName(_ category: String) -> String {
        category.split(separator: "_").map { word in
            let lower = word.lowercased()
            return ["ssh", "api"].contains(lower) ? lower.uppercased() : lower.capitalized
        }.joined(separator: " ")
    }

    private static func symbol(for category: String) -> String {
        switch category.uppercased() {
        case "LOGIN": "person.crop.circle"
        case "PASSWORD": "key"
        case "SSH_KEY": "key.horizontal"
        case "SERVER": "server.rack"
        case "DATABASE": "cylinder"
        case "API_CREDENTIAL": "curlybraces"
        default: "doc"
        }
    }
}
