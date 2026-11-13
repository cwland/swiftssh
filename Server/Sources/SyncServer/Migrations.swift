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
