import SwiftUI
import AppCore

/// The Logs screen: a table of past connections (newest first) with a bookmark toggle per row.
/// All behavior comes from `LogsViewModel`.
struct LogsView: View {
    let model: LogsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Logs")
                .font(.system(size: 22, weight: .semibold))
            let rows = model.rows
            if rows.isEmpty {
                emptyState
            } else {
                table(rows)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contentBackground)
    }

    private func table(_ rows: [LogsViewModel.Row]) -> some View {
        Table(rows) {
            TableColumn("Date") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.dateText)
                        .font(.system(size: 14, weight: .semibold))
                    Text(row.timeRangeText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            TableColumn("User") { row in
                Text(row.deviceName)
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
            TableColumn("Host") { row in
                HStack(spacing: 10) {
                    BadgeView(badge: row.badge, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.hostLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("ssh, \(row.username)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            TableColumn("Saved") { row in
                Button {
                    model.toggleSaved(id: row.id)
                } label: {
                    Image(systemName: row.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15))
                        .foregroundStyle(row.saved ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.saved ? "Remove from saved" : "Save")
            }
            .width(60)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No connections yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Sessions you open appear here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
