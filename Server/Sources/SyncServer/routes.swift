import Vapor

struct HealthResponse: Content {
    var status: String
}

func routes(_ app: Application, apiKeys: Set<String>) throws {
    app.get("health") { _ in HealthResponse(status: "ok") }

    // Authenticated API; later tasks register their routes on this group.
    let v1 = app.grouped("v1").grouped(APIKeyMiddleware(keys: apiKeys))

    // Vapor only runs group middleware on matched routes. These lowest-priority catch-alls make
    // unknown /v1 paths hit the key check first (401 before 404, so routes aren't revealed).
    for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
        v1.on(method, "**") { _ -> Response in throw Abort(.notFound) }
    }
}
