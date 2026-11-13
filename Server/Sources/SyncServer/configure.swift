import CoreModels
import Fluent
import FluentSQLiteDriver
import Vapor

/// Renders every error as `{"error": "<message>"}` with a JSON content type.
struct JSONErrorMiddleware: AsyncMiddleware {
    struct Body: Encodable { let error: String }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let status: HTTPResponseStatus
            let message: String
            if let abort = error as? AbortError {
                status = abort.status
                message = abort.reason
            } else {
                // Never leak internals; details go to the server log (no request bodies).
                request.logger.report(error: error)
                status = .internalServerError
                message = "Internal Server Error"
            }
            let response = Response(status: status)
            response.headers.contentType = .json
            response.body = .init(data: try JSONEncoder().encode(Body(error: message)))
            return response
        }
    }
}

public func configure(_ app: Application, apiKeys: Set<String>, database: DatabaseConfigurationFactory) async throws {
    // Wire dates must match clients: milliseconds since 1970, sorted keys.
    ContentConfiguration.global.use(encoder: CoreJSON.encoder, for: .json)
    ContentConfiguration.global.use(decoder: CoreJSON.decoder, for: .json)

    app.routes.defaultMaxBodySize = "10mb"

    app.middleware = .init()
    app.middleware.use(JSONErrorMiddleware())

    app.databases.use(database, as: .sqlite)
    app.migrations.add(CreateVault())
    app.migrations.add(CreateRecords())
    try await app.autoMigrate()

    try routes(app, apiKeys: apiKeys)
}
