import XCTVapor
@testable import SyncServer

/// Creates and configures an in-memory app, runs `body`, and always awaits shutdown (even on error).
func withApp(
    keys: Set<String> = ["k1"],
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app, apiKeys: keys, database: .sqlite(.memory))
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
