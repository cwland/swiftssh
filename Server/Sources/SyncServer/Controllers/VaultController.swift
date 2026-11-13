import Fluent
import SyncCore
import Vapor

struct VaultController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let vault = routes.grouped("vault")
        vault.get(use: get)
        vault.put(use: put)
        vault.post("rewrap", use: rewrap)
    }

    private func current(_ db: Database) async throws -> VaultRow? {
        try await VaultRow.query(on: db).first()
    }

    func get(req: Request) async throws -> VaultMetadata {
        guard let row = try await current(req.db) else { throw Abort(.notFound, reason: "No vault") }
        return row.metadata
    }

    func put(req: Request) async throws -> Response {
        let meta = try req.content.decode(VaultMetadata.self)
        if try await current(req.db) != nil { throw Abort(.conflict, reason: "Vault already exists") }
        do {
            try await VaultRow(meta).create(on: req.db)
        } catch {
            // A concurrent PUT can win the race; the unique slot turns that into a conflict.
            if try await current(req.db) != nil { throw Abort(.conflict, reason: "Vault already exists") }
            throw error
        }
        let response = Response(status: .created)
        try response.content.encode(meta)
        return response
    }

    func rewrap(req: Request) async throws -> VaultMetadata {
        let body = try req.content.decode(RewrapRequest.self)
        guard let row = try await current(req.db) else { throw Abort(.notFound, reason: "No vault") }
        guard row.wrappedKey == body.oldWrappedKey else {
            throw Abort(.conflict, reason: "Wrapped key does not match")
        }
        row.salt = body.salt
        row.iterations = body.iterations
        row.wrappedKey = body.wrappedKey
        try await row.update(on: req.db)
        return row.metadata
    }
}
