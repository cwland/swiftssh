import Foundation
import Observation
import CoreModels

/// The Snippets screen (and the terminal's snippets panel): snippets grouped by package, search,
/// and edits that save at once through `LocalVault.saveNow` (they sync).
@MainActor @Observable
public final class SnippetsViewModel {
    public var searchText = ""

    @ObservationIgnored private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    public struct Section: Identifiable {
        public let package: String?
        public let snippets: [Snippet]
        public var id: String { package ?? "" }
    }

    public var sections: [Section] { [] } // stub

    public var packages: [String] { [] } // stub

    @discardableResult
    public func create(name: String, script: String, package: String?) -> Snippet {
        vault.saveNow(Snippet(name: name, script: script, package: package)) // stub
    }

    public func update(_ id: UUID, name: String?, script: String?, package: String??) {} // stub

    public func move(_ ids: [UUID], toPackage: String?) {} // stub

    @discardableResult
    public func duplicate(_ id: UUID) -> Snippet? { nil } // stub

    public func delete(_ id: UUID) {} // stub

    public func saveTargets(_ id: UUID, hostIDs: [UUID]?) {} // stub

    public func startupCandidates() -> [Snippet] { [] } // stub
}
