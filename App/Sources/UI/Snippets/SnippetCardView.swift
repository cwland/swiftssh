import SwiftUI
import AppCore
import CoreModels

/// A saved snippet: a "curlybraces" badge, the name, the script's first line in monospaced secondary
/// text and, when it has one, a package chip. Selection draws a blue border (like host cards).
struct SnippetCardView: View {
    let snippet: Snippet
    let isSelected: Bool
    /// The pencil (shown while hovered or selected) opens the editor.
    var onEdit: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.cardPadding) {
            SymbolBadge(symbol: "curlybraces", background: Theme.snippetBadge)
                .frame(width: Theme.cardBadgeSize, height: Theme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(of: snippet))
                    .font(.system(size: Theme.cardTitleFontSize))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.firstLine(of: snippet.script) ?? "Empty script")
                    .font(.system(size: Theme.cardSubtitleFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let package = snippet.package {
                PackageChip(name: package)
            }
            if let onEdit {
                CardEditButton(action: onEdit)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    .allowsHitTesting(isHovering || isSelected)
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }

    static func displayName(of snippet: Snippet) -> String {
        let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled snippet" : name
    }

    /// The first non-blank line, trimmed; nil for an empty script.
    static func firstLine(of script: String) -> String? {
        script.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// A small capsule naming a snippet package.
struct PackageChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Theme.searchFieldBackground)
        }
        .frame(maxWidth: 110, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Theme {
    /// The snippet card badge: a violet that stands apart from group (blue) and key badges.
    static let snippetBadge = Color(hex: "#8B5CF6")
}
