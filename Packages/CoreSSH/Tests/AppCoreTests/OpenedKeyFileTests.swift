import XCTest
@testable import AppCore

/// "Open in SwiftSSH" hands the app its own copy of a private key file; that copy must be found (and
/// deleted) wherever iOS put it: Documents/Inbox, or tmp/<bundle id>-Inbox on current iOS versions,
/// even when the paths differ only by a symlink (/var vs /private/var).
final class OpenedKeyFileTests: XCTestCase {
    private var root: URL!
    private var documents: URL!
    private var temporary: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedKeyFileTests-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        temporary = root.appendingPathComponent("tmp", isDirectory: true)
        for directory: URL in [documents.appendingPathComponent("Inbox"), documents.appendingPathComponent("InboxOther"),
                          temporary.appendingPathComponent("com.cwland.SwiftSSH.mobile-Inbox")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func isCopy(_ url: URL) -> Bool {
        OpenedKeyFile.isAppOwnedCopy(url, documentsDirectory: documents, temporaryDirectory: temporary)
    }

    func testTheDocumentsInboxCopyIsTheAppsOwn() {
        XCTAssertTrue(isCopy(documents.appendingPathComponent("Inbox/id_ed25519")))
    }

    func testTheTmpInboxCopyIsTheAppsOwn() {
        XCTAssertTrue(isCopy(temporary.appendingPathComponent("com.cwland.SwiftSSH.mobile-Inbox/id_ed25519")))
    }

    func testFilesOutsideTheInboxesAreNotTheAppsOwn() {
        XCTAssertFalse(isCopy(documents.appendingPathComponent("id_ed25519")))
        XCTAssertFalse(isCopy(documents.appendingPathComponent("InboxOther/id_ed25519")))
        XCTAssertFalse(isCopy(documents.appendingPathComponent("Inbox/../id_ed25519")))
        XCTAssertFalse(isCopy(URL(fileURLWithPath: "/elsewhere/Inbox/id_ed25519")))
        XCTAssertFalse(isCopy(URL(string: "https://example.com/Inbox/id_ed25519")!))
    }

    func testAPathThroughASymlinkStillMatches() throws {
        let link = root.deletingLastPathComponent().appendingPathComponent("OpenedKeyFileLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        let viaLink = link.appendingPathComponent("tmp/com.cwland.SwiftSSH.mobile-Inbox/id_ed25519")
        XCTAssertTrue(isCopy(viaLink))
        XCTAssertTrue(isCopy(link.appendingPathComponent("Documents/Inbox/key.pem")))
    }
}
