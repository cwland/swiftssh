import CoreModels
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

    /// Runs `body` against a really listening server (port 0, in-memory DB) and its base URL.
    func withRunningServer(_ body: (Application, URL) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, apiKeys: ["k1"], database: .sqlite(.memory))
            // `server.start` rather than `startup()`: the latter parses the test runner's command line.
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            guard let port = app.http.server.shared.localAddress?.port else {
                XCTFail("server has no bound port")
                throw Abort(.internalServerError)
            }
            try await body(app, URL(string: "http://127.0.0.1:\(port)")!)
        } catch {
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

