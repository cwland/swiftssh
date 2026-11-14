import XCTest
import Foundation
import SyncCore
@testable import AppCore

final class VaultKeyRawBytesTests: XCTestCase {
    func testRoundTripsThirtyTwoBytes() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let key = try VaultKey(rawBytes: bytes)
        XCTAssertEqual(key.rawBytes, bytes)
    }

    func testEqualBytesGiveEqualKeys() throws {
        let bytes = Data(repeating: 0xAB, count: 32)
        XCTAssertEqual(try VaultKey(rawBytes: bytes), try VaultKey(rawBytes: bytes))
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(try VaultKey(rawBytes: Data(repeating: 1, count: 16))) { error in
            XCTAssertEqual(error as? VaultKeyBytesError, .wrongLength(16))
        }
        XCTAssertThrowsError(try VaultKey(rawBytes: Data())) { error in
            XCTAssertEqual(error as? VaultKeyBytesError, .wrongLength(0))
        }
    }

    func testRawBytesOfGeneratedKeyAreThirtyTwoBytes() {
        XCTAssertEqual(VaultKey(VaultCrypto.newVaultKey()).rawBytes.count, 32)
    }
}
