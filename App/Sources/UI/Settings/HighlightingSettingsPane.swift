import SwiftUI
import AppCore
import CoreModels

/// Settings → Highlighting: your own highlighting rules (synced to your other Macs through the
/// vault, `HighlightRulesStore`), a live preview line, and the built-in keyword highlighting
/// (per Mac, `KeywordHighlightSettings`). Every change reaches open terminals at once, for output
/// that arrives from then on.
struct HighlightingSettingsPane: View {
    let keywords: KeywordHighlightSettings
    let rules: HighlightRulesStore
    @State private var sample = HighlightingSettingsPane.defaultSample
    /// The rule open in the editor sheet (a new one has an id not in the list yet).
    @State private var editing: HighlightRule?

    static let defaultSample = "ERROR: backup of prod-db failed on 10.0.0.12, warning: retrying"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Highlighting")
                    .font(.system(size: 22, weight: .semibold))

                rulesSection

                previewSection

                KeywordHighlightingSection(settings: keywords)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $editing) { rule in
            HighlightRuleEditor(rule: rule, isNew: !rules.rules.contains { $0.id == rule.id },
                                allRules: rules.rules, sample: sample, keywords: keywords.snapshot) { saved in
                rules.update(saved)
            }
        }
    }

    // MARK: Your rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Your rules")

            VStack(alignment: .leading, spacing: 0) {
                let list = rules.rules
                let errors = rules.compiled.errors
                if !rules.isAvailable {
                    Text("Your rules appear here once the vault is open.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if list.isEmpty {
                    Text("No rules yet. Add one to colour a word, a phrase or a pattern in every terminal, e.g. the name of your production server.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        HighlightRuleRow(rule: rule, error: errors[rule.id], isFirst: index == 0,
                                         isLast: index == list.count - 1, store: rules) {
                            editing = rule
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("Add Rule\u{2026}") { editing = rules.makeNewRule() }
                        .disabled(!rules.isAvailable)
                }
                .padding(.top, 10)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }

            Text("One list for every terminal, synced to your other Macs (end-to-end encrypted). A rule higher in the list wins where two rules match the same text, and your rules win over the built-in keywords. Only output without a colour of its own is highlighted, never in full-screen programs, and a match must fit on one line.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Preview")

            VStack(alignment: .leading, spacing: 10) {
                TextField("Type sample text", text: $sample)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Sample text")
                let segments = HighlightPreview.segments(for: sample, keywords: keywords.snapshot, rules: rules.compiled)
                HighlightPreviewLines(segments: segments)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }
        }
    }
}

/// One rule in the list: on/off, colour, pattern, what kind of rule it is, reorder, edit, delete.
private struct HighlightRuleRow: View {
    let rule: HighlightRule
    /// Why the rule is skipped (invalid regular expression), if it is.
    let error: String?
    let isFirst: Bool
    let isLast: Bool
    let store: HighlightRulesStore
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("On", isOn: Binding(get: { rule.isEnabled }, set: { store.setEnabled($0, id: rule.id) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("\(rule.pattern) on")

            Circle()
                .fill(rule.rgbColor.swiftUIColor)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.pattern)
                    .font(.system(size: 13, weight: rule.isBold ? .bold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)

            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warningForeground)
                    .help(error)
                    .accessibilityLabel("Not used: \(error)")
            }

            Spacer(minLength: 8)

            Button { store.moveUp(id: rule.id) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
                .help("Move up (wins over the rules below)")
                .accessibilityLabel("Move \(rule.pattern) up")
            Button { store.moveDown(id: rule.id) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
                .help("Move down")
                .accessibilityLabel("Move \(rule.pattern) down")
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit rule")
                .accessibilityLabel("Edit \(rule.pattern)")
            Button { store.delete(id: rule.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete rule")
                .accessibilityLabel("Delete \(rule.pattern)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

private extension HighlightRule {
    /// "Word or phrase · Ignores case · Bold", for the list.
    var summary: String {
        var parts = [isRegularExpression ? "Regular expression" : "Word or phrase",
                     matchCase ? "Match case" : "Ignores case"]
        if isBold { parts.append("Bold") }
        if let entry = HighlightPalette.entry(for: rgbColor) { parts.append(entry.name) } else { parts.append("Custom colour") }
        if !isEnabled { parts.append("Off") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The preview text as a terminal would draw it, on a light and on a dark background.
private struct HighlightPreviewLines: View {
    let segments: [HighlightPreview.Segment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(background: Color(hex: "#FFFFFF"), foreground: Color(hex: "#1E1E1E"), name: "Light")
            line(background: Color(hex: "#1E1E1E"), foreground: Color(hex: "#E6E6E6"), name: "Dark")
        }
    }

    private func line(background: Color, foreground: Color, name: String) -> some View {
        Text(attributed(foreground: foreground))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.25))
            }
            .accessibilityLabel("Preview on a \(name.lowercased()) background")
            .accessibilityValue(segments.map(\.text).joined())
    }

    private func attributed(foreground: Color) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
                segment.color?.swiftUIColor ?? foreground
            piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] =
                .system(size: 13, weight: segment.isBold ? .bold : .regular, design: .monospaced)
            result += piece
        }
        if segments.isEmpty {
            var placeholder = AttributedString(" ")
            placeholder[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: 13, design: .monospaced)
            result = placeholder
        }
        return result
    }
}

/// The sheet for adding or editing one rule: pattern, Match case, regular expression, colour,
/// bold, on/off, and a preview of the sample text with this rule (in its place in the list).
private struct HighlightRuleEditor: View {
    let isNew: Bool
    let allRules: [HighlightRule]
    let keywords: KeywordHighlightSettings.Snapshot
    let onSave: (HighlightRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HighlightRule
    @State private var sample: String

    init(rule: HighlightRule, isNew: Bool, allRules: [HighlightRule], sample: String,
         keywords: KeywordHighlightSettings.Snapshot, onSave: @escaping (HighlightRule) -> Void) {
        self.isNew = isNew
        self.allRules = allRules
        self.keywords = keywords
        self.onSave = onSave
        _draft = State(initialValue: rule)
        _sample = State(initialValue: sample)
    }

    /// The draft as it will be saved (a word or phrase loses surrounding spaces).
    private var cleaned: HighlightRule {
        var rule = draft
        if !rule.isRegularExpression {
            rule.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rule
    }

    private var error: String? { cleaned.validationError }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Highlighting Rule" : "Edit Highlighting Rule")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(draft.isRegularExpression ? "Regular expression" : "Word or phrase")
                    .font(.system(size: 13, weight: .medium))
                TextField(draft.isRegularExpression ? "e.g. prod-db-\\d+" : "e.g. prod-db", text: $draft.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .accessibilityLabel(draft.isRegularExpression ? "Regular expression" : "Word or phrase")
                if let error, !cleaned.pattern.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warningForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(draft.isRegularExpression
                     ? "Matches anywhere in a line (ICU syntax, as in NSRegularExpression). Lines longer than \(CompiledHighlightRules.maxRegexLineLength) characters are skipped, and a pattern that takes too long on a line is stopped."
                     : "Matches whole words: \u{201C}prod\u{201D} colours prod and prod-db, not production. A phrase can contain spaces.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Match case", isOn: $draft.matchCase)
            Toggle("Advanced: regular expression", isOn: $draft.isRegularExpression)

            VStack(alignment: .leading, spacing: 6) {
                Text("Colour")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    ForEach(HighlightPalette.colors) { entry in
                        swatch(entry)
                    }
                    Divider().frame(height: 20)
                    ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .help("Custom colour")
                        .accessibilityLabel("Custom colour")
                    if HighlightPalette.entry(for: draft.rgbColor) == nil {
                        Text("Custom")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("Bold", isOn: $draft.isBold)
            Toggle("On", isOn: $draft.isEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.system(size: 13, weight: .medium))
                TextField("Type sample text", text: $sample)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Sample text")
                HighlightPreviewLines(segments: HighlightPreview.segments(for: sample, keywords: keywords,
                                                                          rules: previewRules))
                if !draft.isEnabled {
                    Text("The rule is off: shown here as if it were on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    onSave(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(error != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// The list with this rule in its place (or at the end when new), switched on for the preview.
    private var previewRules: CompiledHighlightRules {
        var rule = cleaned
        rule.isEnabled = true
        var list = allRules
        if let index = list.firstIndex(where: { $0.id == rule.id }) {
            list[index] = rule
        } else {
            list.append(rule)
        }
        return CompiledHighlightRules(rules: list)
    }

    private func swatch(_ entry: HighlightPalette.Entry) -> some View {
        let isSelected = draft.rgbColor == entry.color
        return Button {
            draft.color = entry.color.hex
        } label: {
            Circle()
                .fill(entry.color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .padding(-4)
                        .opacity(isSelected ? 1 : 0)
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var customColor: Binding<Color> {
        Binding(get: { draft.rgbColor.swiftUIColor },
                set: { color in
                    if let rgb = AppCore.RGBColor(srgb: color) { draft.color = rgb.hex }
                })
    }
}

/// Settings → Highlighting → Built-in keywords (package E's `KeywordHighlightSettings`): the master
/// switch and one colour well per category. Changes reach open tabs at once. Your own rules are
/// not affected by the switch.
private struct KeywordHighlightingSection: View {
    let settings: KeywordHighlightSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Built-in keywords")

            VStack(alignment: .leading, spacing: 12) {
                SettingToggle(title: "Highlight keywords",
                              detail: "Colours words like error, warning, ok and info, and IP and MAC addresses, in output that has no colour of its own.",
                              isOn: Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))

                Divider()

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
                          alignment: .leading, spacing: 10) {
                    ForEach(KeywordCategory.allCases) { category in
                        HStack(spacing: 8) {
                            ColorPicker(category.displayName, selection: colorBinding(category), supportsOpacity: false)
                                .labelsHidden()
                            Text(category.displayName)
                                .font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .help(helpText(category))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(category.displayName) colour")
                    }
                }
                .disabled(!settings.isEnabled)

                HStack {
                    Spacer(minLength: 0)
                    Button("Restore Default Colours") { settings.resetAllColors() }
                        .disabled(!settings.isEnabled
                                  || KeywordCategory.allCases.allSatisfy { settings.isDefaultColor(for: $0) })
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }

            Text("Never changes colours a program sets, and stays off in full-screen programs such as vim, htop and less. Saved on this Mac only. Your own rules above are not affected by this switch.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colorBinding(_ category: KeywordCategory) -> Binding<SwiftUI.Color> {
        Binding(get: { settings.color(for: category).swiftUIColor },
                set: { color in
                    if let rgb = AppCore.RGBColor(srgb: color) { settings.setColor(rgb, for: category) }
                })
    }

    private func helpText(_ category: KeywordCategory) -> String {
        let words = category.keywords
        guard !words.isEmpty else { return "IPv4 and IPv6 addresses, MAC addresses" }
        return words.joined(separator: ", ")
    }
}

