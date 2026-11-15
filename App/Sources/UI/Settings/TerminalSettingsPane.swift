import SwiftUI
import AppCore

/// Settings → Terminal: the text size and the app-wide default theme. The theme gallery is two
/// columns of `ThemeCard`s, "Automatic" first, then every bundled theme. Both choices are saved by
/// `TerminalSettings` (this Mac only) and open tabs follow them at once. A host or group with its
/// own theme keeps it.
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
                    Text("Text Size")
                        .font(.system(size: Theme.cardTitleFontSize))
                    Spacer(minLength: 0)
                    TextSizeStepper(settings: settings)
                }

                Text("Theme")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          spacing: 16) {
                    ThemeCard(theme: nil, isSelected: settings.defaultThemeID == nil) {
                        settings.defaultThemeID = nil
                    }
                    ForEach(catalog.themes) { theme in
                        ThemeCard(theme: theme, isSelected: settings.defaultThemeID == theme.id) {
                            settings.defaultThemeID = theme.id
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Theme")

                Text("Applies to every open tab now. A host or group with its own theme keeps it. Saved on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Theme credits\u{2026}") { showsCredits = true }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showsCredits) {
            ThemeCreditsSheet(catalog: catalog)
        }
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

/// One gallery card: the swatch, the name and "Light"/"Dark". `theme == nil` is Automatic.
struct ThemeCard: View {
    let theme: TerminalTheme?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeSwatch(theme: theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: Theme.cardTitleFontSize))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(name)
    }

    private var name: String { theme?.name ?? "Automatic" }

    private var subtitle: String {
        guard let theme else { return "Follows light and dark mode" }
        return theme.appearance == .light ? "Light" : "Dark"
    }

    private var helpText: String {
        guard let theme else { return "Automatic \u{2014} Reimagined Light or Reimagined Dark, following the system appearance" }
        guard let credit = theme.credit else { return theme.name }
        return "\(theme.name) \u{2014} by \(credit.author), \(credit.license)"
    }
}

/// A miniature terminal: background, a foreground bar (60 % of the width), bars in ANSI 1...5 and a
/// cursor block. Automatic draws Reimagined Light and Dark split on the diagonal.
struct ThemeSwatch: View {
    let theme: TerminalTheme?
    var height: CGFloat = 64

    var body: some View {
        Group {
            if let theme {
                SwatchContent(theme: theme)
            } else {
                let catalog = TerminalThemeCatalog.shared
                ZStack {
                    SwatchContent(theme: catalog.automatic(prefersDark: false))
                    SwatchContent(theme: catalog.automatic(prefersDark: true))
                        .clipShape(LowerRightTriangle())
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct SwatchContent: View {
    let theme: TerminalTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.background.swiftUIColor
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.foreground.swiftUIColor)
                        .frame(width: (proxy.size.width - 20) * 0.6, height: 5)
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.ansi[index].swiftUIColor)
                                .frame(height: 5)
                        }
                    }
                    Rectangle()
                        .fill(theme.cursor.swiftUIColor)
                        .frame(width: 7, height: 12)
                }
                .padding(10)
            }
        }
    }
}

/// The bottom-right half of a rectangle, cut along the diagonal.
private struct LowerRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
