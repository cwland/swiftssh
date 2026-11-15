import SwiftUI
import AppKit
import CoreText
import AppCore
import SSHCore

/// Settings → Terminal: font, text size, the app-wide default theme (package A's `ThemeGallery`,
/// "Default" = Automatic first), Behaviour, then Keyword highlighting. Everything is saved per Mac
/// (`TerminalSettings`, `KeywordHighlightSettings`); open tabs follow all of it at once except the
/// terminal type, which applies to new connections. A host or group with its own theme keeps it.
struct TerminalSettingsPane: View {
    let settings: TerminalSettings
    var catalog: TerminalThemeCatalog = .shared
    @State private var showsCredits = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Terminal")
                    .font(.system(size: 22, weight: .semibold))

                HStack {
                    Text("Font")
                        .font(.system(size: Theme.cardTitleFontSize))
                    Spacer(minLength: 0)
                    TerminalFontPicker(settings: settings)
                }

                HStack {
                    Text("Text Size")
                        .font(.system(size: Theme.cardTitleFontSize))
                    Spacer(minLength: 0)
                    TextSizeStepper(settings: settings)
                }

                SectionHeading("Theme")

                ThemeGallery(catalog: catalog, selectedThemeID: settings.defaultThemeID, inheritedTheme: nil,
                             showsDefault: true, columns: 2) { id in
                    settings.defaultThemeID = id
                }
                .accessibilityLabel("Theme")

                Text("Applies to every open tab now. A host or group with its own theme keeps it. Saved on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Theme credits\u{2026}") { showsCredits = true }

                TerminalBehaviourSection(settings: settings)

                KeywordHighlightingSection(settings: TerminalHighlighting.settings)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showsCredits) {
            ThemeCreditsSheet(catalog: catalog)
        }
    }
}

/// A pane section's small grey heading.
private struct SectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Settings → Terminal → Behaviour: links, select-to-copy, bell, Option as Meta, bold as bright
/// (all live on open tabs) and the terminal type (new connections).
private struct TerminalBehaviourSection: View {
    let settings: TerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Behaviour")

            VStack(alignment: .leading, spacing: 12) {
                SettingToggle(title: "Open links with \u{2318}-click",
                              detail: "Hold \u{2318} to underline web and mail links; \u{2318}-click opens them in your browser or mail app.",
                              isOn: Binding(get: { settings.opensLinksWithCommandClick },
                                            set: { settings.opensLinksWithCommandClick = $0 }))
                SettingToggle(title: "Select text to copy & right-click to paste",
                              detail: "Selected text goes to the clipboard at once; a right-click pastes it.",
                              isOn: Binding(get: { settings.selectToCopyRightClickToPaste },
                                            set: { settings.selectToCopyRightClickToPaste = $0 }))
                SettingToggle(title: "Bell sound",
                              detail: "Play the system alert sound when a program rings the bell. Off: the bell is silent.",
                              isOn: Binding(get: { settings.bellSound }, set: { settings.bellSound = $0 }))
                SettingToggle(title: "Use Option as Meta key",
                              detail: "Option+key sends Esc then the key, for shells and editors (Option+B, Option+F). Off: Option types special characters.",
                              isOn: Binding(get: { settings.optionAsMetaKey }, set: { settings.optionAsMetaKey = $0 }))
                SettingToggle(title: "Use bright colours for bold text",
                              detail: "Bold text in the 8 basic colours is drawn in their bright versions.",
                              isOn: Binding(get: { settings.boldUsesBrightColors },
                                            set: { settings.boldUsesBrightColors = $0 }))

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Terminal type")
                            .font(.system(size: Theme.cardTitleFontSize))
                        Text("The TERM value sent to the server. Applies to new connections.")
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("Terminal type", selection: Binding(get: { settings.terminalType },
                                                              set: { settings.terminalType = $0 })) {
                        ForEach(TerminalType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }

            Text("Saved on this Mac only. Open tabs follow these at once, except the terminal type.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings → Terminal → Keyword highlighting (package E's `KeywordHighlightSettings`): the master
/// switch and one colour well per category. Changes reach open tabs at once.
private struct KeywordHighlightingSection: View {
    let settings: KeywordHighlightSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Keyword highlighting")

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

            Text("Never changes colours a program sets, and stays off in full-screen programs such as vim, htop and less. Saved on this Mac only.")
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

// Qualified: legacy QuickDraw headers (via AppKit) also declare a C `RGBColor`.
private extension AppCore.RGBColor {
    /// A colour well's colour in sRGB, rounded to 8 bits a component; nil if it has no sRGB form
    /// (a pattern colour).
    init?(srgb color: SwiftUI.Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * 255).rounded())
        }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }
}

/// A switch with a title and a grey line under it.
private struct SettingToggle: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.cardTitleFontSize))
                Text(detail)
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}

/// The Font row's button: the current family, drawn in itself. It opens a list of the Mac's
/// monospaced families, SF Mono first, each drawn in its own font, with a check on the current one.
/// A chosen family that is no longer installed is drawn in SF Mono and says so.
struct TerminalFontPicker: View {
    let settings: TerminalSettings
    @State private var showsList = false

    var body: some View {
        let chosen = settings.fontName
        let installed = chosen.map { TerminalFonts.isInstalled($0) } ?? true
        Button {
            showsList.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(chosen ?? TerminalFonts.systemName)
                    .font(TerminalFonts.font(family: installed ? chosen : nil, size: 13))
                if !installed {
                    Text("(not installed \u{2014} using SF Mono)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Font, \(chosen ?? TerminalFonts.systemName)")
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            TerminalFontList(selected: chosen) { family in
                settings.fontName = family
            }
        }
    }
}

/// The popover list. Clicking a row applies it at once (open tabs too) and keeps the list open
/// for comparing; Esc or a click outside closes it.
private struct TerminalFontList: View {
    let selected: String?
    let select: (String?) -> Void
    /// nil while the list is being built (a moment, off the main thread, on the first open).
    @State private var families: [String]? = TerminalFonts.cachedFamilies

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(nil)
                    if let families {
                        ForEach(families, id: \.self) { family in
                            row(family)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding monospaced fonts\u{2026}")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 6)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)

            Divider()
            Text("Other monospaced fonts appear here once installed, e.g. JetBrains Mono, Fira Mono or Source Code Pro.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .frame(width: 300)
        .task {
            if families == nil { families = await TerminalFonts.monospacedFamilies() }
        }
    }

    private func row(_ family: String?) -> some View {
        let isSelected = family == selected
        return Button {
            select(family)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Text(family ?? TerminalFonts.systemName)
                    .font(TerminalFonts.font(family: family, size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(family ?? TerminalFonts.systemName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The Mac's monospaced fonts, through AppKit.
@MainActor
enum TerminalFonts {
    static let systemName = "SF Mono"

    /// Fixed-pitch families installed on this Mac (not SF Mono, which is always the first row),
    /// sorted by name. Built once per app run, off the main thread, from font descriptors only
    /// (no font is loaded); fonts installed later appear after a relaunch.
    static func monospacedFamilies() async -> [String] {
        if let cachedFamilies { return cachedFamilies }
        let list = await Task.detached(priority: .userInitiated) { loadMonospacedFamilies() }.value
        cachedFamilies = list
        return list
    }

    private(set) static var cachedFamilies: [String]?

    /// CoreText (thread-safe): every installed face whose symbolic traits say monospaced.
    nonisolated private static func loadMonospacedFamilies() -> [String] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor]) ?? []
        let families = descriptors.compactMap { descriptor -> String? in
            guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any],
                  let symbolic = (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value,
                  CTFontSymbolicTraits(rawValue: symbolic).contains(.traitMonoSpace) else { return nil }
            return CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        }
        return TerminalFontChoice.pickerFamilies(fixedPitch: families)
    }

    static func isInstalled(_ family: String) -> Bool {
        SessionTerminalView.font(family: family, size: 13) != nil
    }

    /// `family` (nil or missing = SF Mono) as a SwiftUI font.
    static func font(family: String?, size: CGFloat) -> Font {
        Font(SessionTerminalView.terminalFont(family: family, size: Int(size)) as CTFont)
    }
}

/// `[ − ]  13  [ + ]` for the terminal text size. The buttons disable at the ends of the range.
struct TextSizeStepper: View {
    let settings: TerminalSettings

    var body: some View {
        HStack(spacing: 10) {
            Button {
                settings.decreaseFontSize()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .disabled(!settings.canDecreaseFontSize)
            .accessibilityLabel("Smaller text")

            Text("\(settings.fontSize)")
                .font(.system(size: Theme.cardTitleFontSize).monospacedDigit())
                .frame(minWidth: 28)

            Button {
                settings.increaseFontSize()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .disabled(!settings.canIncreaseFontSize)
            .accessibilityLabel("Bigger text")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text size, \(settings.fontSize) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settings.increaseFontSize()
            case .decrement: settings.decreaseFontSize()
            @unknown default: break
            }
        }
    }
}

/// The credits sheet: project, author and license for each bundled third-party theme, then the
/// full notice text.
struct ThemeCreditsSheet: View {
    let catalog: TerminalThemeCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme credits")
                .font(.system(size: 22, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(catalog.credits, id: \.key) { credit in
                    HStack(spacing: 6) {
                        Text("\(credit.project) \u{2014} \(credit.author) (\(credit.license))")
                            .font(.system(size: 13))
                        if let url = URL(string: credit.url) {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help(credit.url)
                            .accessibilityLabel("Open \(credit.project) on the web")
                        }
                    }
                }
            }

            ScrollView {
                Text(TerminalThemeCatalog.noticesText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
    }
}
