import SwiftUI

/// Termius-style card: a badge, then a single-line title (15 pt) and subtitle (12 pt).
public struct CardRow<Badge: View>: View {
    let title: String
    let subtitle: String
    var isSelected: Bool
    /// When set, a pencil button at the right edge (while hovered or selected) opens the editor.
    var onEdit: (() -> Void)?
    let badge: () -> Badge

    @State private var isHovering = false

    public init(title: String, subtitle: String, isSelected: Bool = false, onEdit: (() -> Void)? = nil,
                @ViewBuilder badge: @escaping () -> Badge) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.onEdit = onEdit
        self.badge = badge
    }

    public var body: some View {
        HStack(spacing: SwiftSSHTheme.cardPadding) {
            badge()
                .frame(width: SwiftSSHTheme.cardBadgeSize, height: SwiftSSHTheme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: SwiftSSHTheme.cardTitleFontSize))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: SwiftSSHTheme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let onEdit {
                CardEditButton(action: onEdit)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    .allowsHitTesting(isHovering || isSelected)
            }
        }
        .padding(.horizontal, SwiftSSHTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SwiftSSHTheme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: SwiftSSHTheme.cardCornerRadius, style: .continuous)
                .fill(SwiftSSHTheme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: SwiftSSHTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? SwiftSSHTheme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: SwiftSSHTheme.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

/// The card's pencil: a rounded grey square (as in Termius) that opens the card's editor.
public struct CardEditButton: View {
    let action: () -> Void
    @State private var isHovering = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.16 : 0.09))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Edit")
        .accessibilityLabel("Edit")
    }
}

/// A rounded-square symbol badge for cards that have no OS badge (groups, identities, keys).
public struct SymbolBadge: View {
    let symbol: String
    let background: Color
    var foreground: Color

    public init(symbol: String, background: Color, foreground: Color = .white) {
        self.symbol = symbol
        self.background = background
        self.foreground = foreground
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: SwiftSSHTheme.cardBadgeCornerRadius, style: .continuous)
            .fill(background)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: SwiftSSHTheme.cardBadgeSize * 0.42, weight: .medium))
                    .foregroundStyle(foreground)
            }
    }
}

/// A host group's card: folder symbol, name and "N hosts".
public struct GroupCard: View {
    let name: String
    let hostCount: Int
    var isSelected: Bool
    var onEdit: (() -> Void)?

    public init(name: String, hostCount: Int, isSelected: Bool = false, onEdit: (() -> Void)? = nil) {
        self.name = name
        self.hostCount = hostCount
        self.isSelected = isSelected
        self.onEdit = onEdit
    }

    public var body: some View {
        CardRow(title: name.isEmpty ? "Untitled group" : name,
                subtitle: hostCount == 1 ? "1 host" : "\(hostCount) hosts",
                isSelected: isSelected, onEdit: onEdit) {
            SymbolBadge(symbol: "folder.fill", background: SwiftSSHTheme.accent.opacity(0.15),
                        foreground: SwiftSSHTheme.accent)
        }
    }
}
