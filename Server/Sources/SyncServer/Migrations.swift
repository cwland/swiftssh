import Fluent

struct CreateVault: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(VaultRow.schema)
            .id()
            .field("slot", .int, .required)
            .field("salt", .data, .required)
            .field("iterations", .int, .required)
            .field("wrapped_key", .data, .required)
            .field("version", .int, .required)
            .unique(on: "slot")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(VaultRow.schema).delete()
    }
}

struct CreateRecords: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RecordRow.schema)
            .id()
            .field("type", .string, .required)
            .field("updated_at", .int64, .required)
            .field("deleted", .bool, .required)
            .field("device_id", .string, .required)
            .field("seq", .int64, .required)
            .field("ciphertext", .data, .required)
            .unique(on: "seq")  // SQLite backs a UNIQUE constraint with an index.
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(RecordRow.schema).delete()
    }
}
