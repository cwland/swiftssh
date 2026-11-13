import Vapor

/// Requires `Authorization: Bearer <key>` where `<key>` is one of the configured keys.
/// With no keys configured every request is rejected.
public struct APIKeyMiddleware: AsyncMiddleware {
    public let keys: Set<String>

    public init(keys: Set<String>) {
        self.keys = keys
    }

    /// Parses a comma-separated key list; whitespace is trimmed and empties are dropped.
    public static func parse(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token,
              !token.isEmpty,
              keys.contains(token)
        else {
            throw Abort(.unauthorized, reason: "Unauthorized")
        }
        return try await next.respond(to: request)
    }
}
