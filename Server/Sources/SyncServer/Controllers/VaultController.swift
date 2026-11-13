import Fluent
import FluentSQL
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
        guard let sql = req.db as? SQLDatabase else { throw Abort(.internalServerError) }
        // Compare-and-swap in one statement: the old-key check is part of the write, so of
        // concurrent rewraps sharing an old key at most one can match.
        let updated = try await sql.update(VaultRow.schema)
            .set("salt", to: SQLBind(body.salt))
            .set("iterations", to: SQLBind(body.iterations))
            .set("wrapped_key", to: SQLBind(body.wrappedKey))
            .where("slot", .equal, SQLLiteral.numeric("1"))
            .where("wrapped_key", .equal, SQLBind(body.oldWrappedKey))
            .returning("id")
            .all()
        if updated.isEmpty {
            if try await current(req.db) == nil { throw Abort(.notFound, reason: "No vault") }
            throw Abort(.conflict, reason: "Wrapped key does not match")
        }
        guard let row = try await current(req.db) else { throw Abort(.notFound, reason: "No vault") }
        return row.metadata
    }
}
