import XCTVapor
import CoreModels
import SyncCore
@testable import SyncServer

final class RecordsTests: XCTestCase {
    private let auth: HTTPHeaders = ["Authorization": "Bearer k1"]

    private func record(
        id: UUID = UUID(), ms: Int64 = 1_700_000_000_000, deleted: Bool = false,
        device: String = "A", bytes: [UInt8] = [1, 2, 3]
    ) -> EncryptedRecord {
        EncryptedRecord(
            id: id, type: .host, updatedAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
            deleted: deleted, deviceID: device, ciphertext: Data(bytes))
    }

    private func upsert(_ app: Application, _ records: [EncryptedRecord]) async throws -> [EncryptedRecord] {
        var out: [EncryptedRecord] = []
        try await app.test(.POST, "v1/records", headers: auth, beforeRequest: {
            try $0.content.encode(UpsertRequest(records: records))
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            out = try res.content.decode(UpsertResponse.self).records
        }
        return out
    }

    private func fetch(_ app: Application, _ query: String) async throws -> RecordsPage {
        var page = RecordsPage(records: [], nextSince: -1, hasMore: false)
        try await app.test(.GET, "v1/records?\(query)", headers: auth) { res async throws in
            XCTAssertEqual(res.status, .ok)
            page = try res.content.decode(RecordsPage.self)
        }
        return page
    }

    private func withSeq(_ r: EncryptedRecord, _ seq: Int64) -> EncryptedRecord {
        var r = r
        r.seq = seq
        return r
    }

    func testUpsertNewRecordAssignsSeq() async throws {
        try await withApp { app in
            let a = record(), b = record()
            let got1 = try await upsert(app, [a])
            XCTAssertEqual(got1, [withSeq(a, 1)])
            let got2 = try await upsert(app, [b])
            XCTAssertEqual(got2, [withSeq(b, 2)])
        }
    }

    func testOlderUpdateIsIgnoredAndStoredCopyReturned() async throws {
        try await withApp { app in
            let id = UUID()
            let newer = record(id: id, ms: 2_000, bytes: [9])
            let older = record(id: id, ms: 1_000, device: "Z", bytes: [1])
            _ = try await upsert(app, [newer])
            let got3 = try await upsert(app, [older])
            XCTAssertEqual(got3, [withSeq(newer, 1)])
            let got4 = try await fetch(app, "since=0")
            XCTAssertEqual(got4.records, [withSeq(newer, 1)])
        }
    }

    func testNewerUpdateReplacesAndGetsNewSeq() async throws {
        try await withApp { app in
            let id = UUID()
            let older = record(id: id, ms: 1_000, bytes: [1])
            let other = record()
            let newer = record(id: id, ms: 2_000, device: "B", bytes: [2])
            _ = try await upsert(app, [older, other])
            let got5 = try await upsert(app, [newer])
            XCTAssertEqual(got5, [withSeq(newer, 3)])
            let page = try await fetch(app, "since=0")
            XCTAssertEqual(page.records, [withSeq(other, 2), withSeq(newer, 3)])
        }
    }

    func testTiedTimestampLargerDeviceIDWins() async throws {
        try await withApp { app in
            let id = UUID()
            let fromA = record(id: id, ms: 5_000, device: "A", bytes: [1])
            let fromB = record(id: id, ms: 5_000, device: "B", bytes: [2])
            _ = try await upsert(app, [fromB])
            let got6 = try await upsert(app, [fromA])
            XCTAssertEqual(got6, [withSeq(fromB, 1)])
        }
        try await withApp { app in
            let id = UUID()
            let fromA = record(id: id, ms: 5_000, device: "A", bytes: [1])
            let fromB = record(id: id, ms: 5_000, device: "B", bytes: [2])
            _ = try await upsert(app, [fromA])
            let got7 = try await upsert(app, [fromB])
            XCTAssertEqual(got7, [withSeq(fromB, 2)])
        }
    }

    func testTombstoneIsStoredAndReturned() async throws {
        try await withApp { app in
            let id = UUID()
            _ = try await upsert(app, [record(id: id, ms: 1_000)])
            let tomb = record(id: id, ms: 2_000, deleted: true, bytes: [])
            let got8 = try await upsert(app, [tomb])
            XCTAssertEqual(got8, [withSeq(tomb, 2)])
            let page = try await fetch(app, "since=1")
            XCTAssertEqual(page.records, [withSeq(tomb, 2)])
            XCTAssertTrue(page.records[0].deleted)
        }
    }

    func testResendingIdenticalRecordIsHarmless() async throws {
        try await withApp { app in
            let r = record()
            let got9 = try await upsert(app, [r])
            XCTAssertEqual(got9, [withSeq(r, 1)])
            let got10 = try await upsert(app, [r])
            XCTAssertEqual(got10, [withSeq(r, 1)])
            let page = try await fetch(app, "since=0")
            XCTAssertEqual(page.records, [withSeq(r, 1)])
            XCTAssertEqual(page.nextSince, 1)
        }
    }

    func testSubMillisecondUpdatedAtIsFlooredToWholeMilliseconds() async throws {
        // Clients floor too (Timestamps, the record AAD); rounding up would break both.
        XCTAssertEqual(RecordRow.millis(Date(timeIntervalSince1970: 1_700_000_000.1239)), 1_700_000_000_123)
        try await withApp { app in
            var r = record()
            r.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.1239)
            let stored = try await upsert(app, [r])
            XCTAssertEqual(stored.first?.updatedAt, Date(timeIntervalSince1970: 1_700_000_000_123 / 1000))
            let page = try await fetch(app, "since=0")
            XCTAssertEqual(page.records.first?.updatedAt, Date(timeIntervalSince1970: 1_700_000_000_123 / 1000))
        }
    }

    func testFetchSinceReturnsOnlyLaterRecordsInOrder() async throws {
        try await withApp { app in
            let rs = (0..<4).map { _ in record() }
            for r in rs { _ = try await upsert(app, [r]) }
            let page = try await fetch(app, "since=2")
            XCTAssertEqual(page.records, [withSeq(rs[2], 3), withSeq(rs[3], 4)])
            XCTAssertEqual(page.nextSince, 4)
            XCTAssertFalse(page.hasMore)
            let empty = try await fetch(app, "since=4")
            XCTAssertEqual(empty, RecordsPage(records: [], nextSince: 4, hasMore: false))
        }
    }

    func testEmptyPageAfterRewindReportsMaxSeq() async throws {
        try await withApp { app in
            let none = try await fetch(app, "since=7")
            XCTAssertEqual(none, RecordsPage(records: [], nextSince: 0, hasMore: false))
            _ = try await upsert(app, [record(), record()])
            // A client that saw seq 9 before the server was restored from a backup holding seq 1...2.
            let rewound = try await fetch(app, "since=9")
            XCTAssertEqual(rewound, RecordsPage(records: [], nextSince: 2, hasMore: false))
            let caughtUp = try await fetch(app, "since=2")
            XCTAssertEqual(caughtUp, RecordsPage(records: [], nextSince: 2, hasMore: false))
        }
    }

    func testPagingWithLimitSetsHasMoreAndNextSince() async throws {
        try await withApp { app in
            _ = try await upsert(app, (0..<5).map { _ in record() })
            let p1 = try await fetch(app, "since=0&limit=2")
            XCTAssertEqual(p1.records.map(\.seq), [1, 2]); XCTAssertEqual(p1.nextSince, 2); XCTAssertTrue(p1.hasMore)
            let p2 = try await fetch(app, "since=\(p1.nextSince)&limit=2")
            XCTAssertEqual(p2.records.map(\.seq), [3, 4]); XCTAssertEqual(p2.nextSince, 4); XCTAssertTrue(p2.hasMore)
            let p3 = try await fetch(app, "since=\(p2.nextSince)&limit=2")
            XCTAssertEqual(p3.records.map(\.seq), [5]); XCTAssertEqual(p3.nextSince, 5); XCTAssertFalse(p3.hasMore)
        }
    }

    func testFetchDefaultsToSinceZero() async throws {
        try await withApp { app in
            _ = try await upsert(app, [record()])
            let got11 = try await fetch(app, "")
            XCTAssertEqual(got11.records.count, 1)
        }
    }

    func testLimitIsClampedTo500() async throws {
        try await withApp { app in
            _ = try await upsert(app, (0..<500).map { _ in record() })
            _ = try await upsert(app, (0..<5).map { _ in record() })
            let page = try await fetch(app, "since=0&limit=100000")
            XCTAssertEqual(page.records.count, 500)
            XCTAssertEqual(page.nextSince, 500)
            XCTAssertTrue(page.hasMore)
        }
    }

    func testOversizedCiphertextIs413() async throws {
        try await withApp { app in
            let big = EncryptedRecord(
                id: UUID(), type: .host, updatedAt: Date(), deleted: false, deviceID: "A",
                ciphertext: Data(repeating: 7, count: 2 * 1024 * 1024))
            try await app.test(.POST, "v1/records", headers: auth, beforeRequest: {
                try $0.content.encode(UpsertRequest(records: [big]))
            }) { res async in
                XCTAssertEqual(res.status, .payloadTooLarge)
            }
            let got12 = try await fetch(app, "since=0")
            XCTAssertEqual(got12.records, [])
        }
    }

    func testMalformedJSONIs400() async throws {
        try await withApp { app in
            var headers = auth
            headers.contentType = .json
            try await app.test(.POST, "v1/records", headers: headers, body: ByteBuffer(string: "{\"records\": [")) { res async in
                XCTAssertEqual(res.status, .badRequest)
            }
        }
    }

    func testMoreThan500RecordsInOneUpsertIs400() async throws {
        try await withApp { app in
            try await app.test(.POST, "v1/records", headers: auth, beforeRequest: {
                try $0.content.encode(UpsertRequest(records: (0..<501).map { _ in self.record() }))
            }) { res async in
                XCTAssertEqual(res.status, .badRequest)
            }
            let got13 = try await fetch(app, "since=0")
            XCTAssertEqual(got13.records, [])
        }
    }

    func testRecordsRequireAPIKey() async throws {
        try await withApp { app in
            try await app.test(.GET, "v1/records") { res async in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    func testConcurrentUpsertsGetUniqueContiguousSeqs() async throws {
        try await withApp { app in
            let n = 10
            let records = (0..<n).map { _ in record() }
            let auth = self.auth
            let seqs = try await withThrowingTaskGroup(of: Int64?.self) { group in
                for r in records {
                    group.addTask {
                        var seq: Int64?
                        try await app.test(.POST, "v1/records", headers: auth, beforeRequest: {
                            try $0.content.encode(UpsertRequest(records: [r]))
                        }) { res async throws in
                            XCTAssertEqual(res.status, .ok)
                            seq = try res.content.decode(UpsertResponse.self).records.first?.seq
                        }
                        return seq
                    }
                }
                var all: [Int64?] = []
                for try await s in group { all.append(s) }
                return all
            }
            XCTAssertEqual(seqs.compactMap { $0 }.sorted(), (1...Int64(n)).map { $0 })
            let page = try await fetch(app, "since=0")
            XCTAssertEqual(page.records.map(\.seq), (1...Int64(n)).map { $0 })
            XCTAssertEqual(Set(page.records.map(\.id)), Set(records.map(\.id)))
        }
    }
}
