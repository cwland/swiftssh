import Vapor
import SyncServer

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)
app.http.server.configuration.hostname = "0.0.0.0"
app.http.server.configuration.port = 8080
do {
    try await configure(
        app,
        apiKeys: APIKeyMiddleware.parse(Environment.get("SYNC_API_KEYS")),
        database: .sqlite(.file(Environment.get("DATABASE_PATH") ?? "/data/sync.sqlite"))
    )
    try await app.execute()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    throw error
}
try await app.asyncShutdown()
