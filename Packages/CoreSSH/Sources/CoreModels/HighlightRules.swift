import Foundation

/// One custom highlighting rule (Settings → Highlighting): a word or phrase, or a regular
/// expression, coloured in every terminal's output.
///
/// Stored inside `TerminalHighlightRules.rules`, not as a record of its own. Decoding is lenient:
/// a missing field takes its default (so a rule written by a newer app version with fewer or
/// renamed fields still loads) and only `pattern` is required. New fields must be optional; note
/// that fields nested in a record are not kept by older app versions when they save the record
/// (see `PlainRecord.encode(_:keepingUnknownFieldsOf:)`), so a v0.11 Mac editing the list drops
/// rule fields it doesn't know.
public struct HighlightRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The word or phrase (matched as whole words), or the regular expression (ICU syntax).
    public var pattern: String
    /// "Advanced: regular expression": `pattern` is a regular expression, not literal text.
    public var isRegularExpression: Bool
    /// "Match case": off matches regardless of case (the default).
    public var matchCase: Bool
    /// "#RRGGBB" (sRGB). An unparsable value draws in the first palette colour.
    public var color: String
    /// Draw matches in bold (only where the text isn't already bold or faint).
    public var isBold: Bool
    /// The rule's on/off switch.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), pattern: String, isRegularExpression: Bool = false, matchCase: Bool = false,
                color: String, isBold: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.isRegularExpression = isRegularExpression
        self.matchCase = matchCase
        self.color = color
        self.isBold = isBold
        self.isEnabled = isEnabled
    }

    /// Lenient: every field but `pattern` falls back to its default when missing or of another type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decode(String.self, forKey: .pattern)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isRegularExpression = (try? container.decodeIfPresent(Bool.self, forKey: .isRegularExpression)) ?? false
        matchCase = (try? container.decodeIfPresent(Bool.self, forKey: .matchCase)) ?? false
        color = (try? container.decodeIfPresent(String.self, forKey: .color)) ?? ""
        isBold = (try? container.decodeIfPresent(Bool.self, forKey: .isBold)) ?? false
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }
}

/// The custom highlighting rules: one list for every terminal on every Mac, synced through the
/// vault (end-to-end encrypted). There is exactly one such record, `singletonID`, so two Macs
/// that each create the list write the same record (no duplicates). The list is edited as a
/// whole. When a pulled list meets a local list that hasn't synced yet (a merge join, or edits on
/// two Macs before they sync), `LocalVault` keeps both: `union(vault:local:preferLocalVersions:)`.
/// Otherwise the newer list wins, as for every record.
///
/// Decoding is lenient per rule: a rule that doesn't decode (written by a newer app version) is
/// skipped, and the rest of the list loads. If `rules` itself doesn't decode, the whole record
/// doesn't, and `HighlightRulesStore` shows the list read-only instead of overwriting it.
///
/// Record type: this record is tagged `SyncRecordType.aiSettings`, the vault's settings slot,
/// instead of a new type, because app versions before v0.11 fail a whole sync pull on a record
/// type they don't know (`EncryptedRecord.type` is a closed enum). Those versions ignore this
/// record: they only read `.aiSettings` records as `AISettings`, which this payload doesn't
/// decode as (`baseURL`/`model` missing), and they never re-encode it. Look it up by id
/// (`LocalVault.get(_:id:)`), never with `all(_:)`, which would also try `AISettings` records.
public struct TerminalHighlightRules: SyncableModel {
    public static let recordType = SyncRecordType.aiSettings
    /// The one record's id, the same on every Mac.
    public static let singletonID = UUID(uuidString: "6C1B2E1A-0B5D-4E0C-9D6A-48494C495445")!

    public var id: UUID
    /// In priority order: where two rules match overlapping text, the earlier rule wins.
    public var rules: [HighlightRule]
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = TerminalHighlightRules.singletonID, rules: [HighlightRule], updatedAt: Date = Date(),
                deleted: Bool = false) {
        self.id = id
        self.rules = rules
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    /// Lenient for `rules`' elements: one that doesn't decode is skipped (see the type's notes).
    /// Uses the synthesized coding keys (encoding stays synthesized).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rules = try container.decode([SkippingInvalid].self, forKey: .rules).compactMap(\.rule)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deleted = try container.decode(Bool.self, forKey: .deleted)
    }

    /// One element of `rules`: always decodes, holding nil when the element isn't a readable rule.
    private struct SkippingInvalid: Decodable {
        let rule: HighlightRule?
        init(from decoder: any Decoder) throws {
            rule = try? HighlightRule(from: decoder)
        }
    }

    /// Two copies of the list united, so neither Mac's rules are lost: `vault`'s rules in its
    /// order, then the rules only `local` has, in their order. A rule in both (same id) takes
    /// `local`'s version when `preferLocalVersions` (the local copy is the newer edit), else the
    /// vault's. A rule deleted from one copy but still in the other comes back.
    public static func union(vault: [HighlightRule], local: [HighlightRule],
                             preferLocalVersions: Bool) -> [HighlightRule] {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var result: [HighlightRule] = []
        for rule in vault where seen.insert(rule.id).inserted {
            result.append(preferLocalVersions ? localByID[rule.id] ?? rule : rule)
        }
        for rule in local where seen.insert(rule.id).inserted {
            result.append(rule)
        }
        return result
    }
}
