import Fluent
import FluentSQL
import SyncCore
import Vapor

struct RecordsController: RouteCollection {
    static let maxBatch = 500
    static let defaultLimit = 200
    static let maxLimit = 500
    static let maxCiphertextBytes = 1024 * 1024

    /// Keeps upserts in this process one at a time, so waiting writers queue here instead of
    /// spinning in SQLite's busy handler on the shared blocking thread pool.
    let writers = WriterQueue()

    func boot(routes: RoutesBuilder) throws {
        let records = routes.grouped("records")
        records.get(use: fetch)
        records.post(use: upsert)
    }

    struct FetchQuery: Decodable {
        var since: Int64?
        var limit: Int?
    }

    func fetch(req: Request) async throws -> RecordsPage {
        let query = try req.query.decode(FetchQuery.self)
        let since = query.since ?? 0
        let limit = min(max(query.limit ?? Self.defaultLimit, 1), Self.maxLimit)
        // One extra row tells us whether another page exists.
        let rows = try await RecordRow.query(on: req.db)
            .filter(\.$seq > since)
            .sort(\.$seq, .ascending)
            .limit(limit + 1)
            .all()
        let page = rows.prefix(limit).map(\.record)
        return RecordsPage(records: page, nextSince: page.last?.seq ?? since, hasMore: rows.count > limit)
    }

    func upsert(req: Request) async throws -> UpsertResponse {
        let body = try req.content.decode(UpsertRequest.self)
        guard body.records.count <= Self.maxBatch else {
            throw Abort(.badRequest, reason: "At most \(Self.maxBatch) records per request")
        }
        guard body.records.allSatisfy({ $0.ciphertext.count <= Self.maxCiphertextBytes }) else {
            throw Abort(.payloadTooLarge, reason: "Record ciphertext exceeds 1 MB")
        }
        let stored = try await writers.run {
            try await Self.writeTransaction(on: req.db) { db in try await Self.merge(body.records, on: db) }
        }
        return UpsertResponse(records: stored)
    }

    /// Runs `body` in a transaction that holds SQLite's write lock from the start
    /// (`BEGIN IMMEDIATE`). Reading the current max `seq` inside it therefore can't race another
    /// writer, and commits become visible in `seq` order: a reader can never see seq N+1 while N
    /// is still pending, which would make an incremental `since=` fetch skip N forever.
    private static func writeTransaction<T: Sendable>(
        on database: Database, _ body: @escaping @Sendable (Database) async throws -> T
    ) async throws -> T {
        try await database.withConnection { db in
            guard let sql = db as? SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("BEGIN IMMEDIATE TRANSACTION").run()
            do {
                let result = try await body(db)
                try await sql.raw("COMMIT TRANSACTION").run()
                return result
            } catch {
                try? await sql.raw("ROLLBACK TRANSACTION").run()
                throw error
            }
        }
    }

    /// Applies `MergeRule` per record; each accepted write gets the next `seq`. Returns the stored
    /// copy of every submitted id, in first-submitted order.
    private static func merge(_ incoming: [EncryptedRecord], on db: Database) async throws -> [EncryptedRecord] {
        guard let sql = db as? SQLDatabase else { throw Abort(.internalServerError) }
        struct MaxSeq: Decodable { var m: Int64 }
        let current = try await sql.raw("SELECT COALESCE(MAX(seq), 0) AS m FROM records")
            .first(decoding: MaxSeq.self)?.m ?? 0
        var nextSeq = current + 1

        var rows: [UUID: RecordRow] = [:]
        var order: [UUID] = []
        for record in incoming {
            if !order.contains(record.id) {
                order.append(record.id)
                rows[record.id] = try await RecordRow.find(record.id, on: db)
            }
            if let existing = rows[record.id] {
                let key = (updatedAt: RecordRow.date(RecordRow.millis(record.updatedAt)), deviceID: record.deviceID)
                guard MergeRule.incomingWins(key, over: existing.mergeKey) else { continue }
                existing.apply(record, seq: nextSeq)
                try await existing.update(on: db)
            } else {
                let row = RecordRow(record, seq: nextSeq)
                try await row.create(on: db)
                rows[record.id] = row
            }
            nextSeq += 1
        }
        return order.compactMap { rows[$0]?.record }
    }
}

/// A FIFO async mutex.
actor WriterQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
