import Foundation
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SyncTransportError: Error, Equatable {
    /// The server (or the reverse proxy in front of it) rejected the API key (HTTP 401 or 403).
    case unauthorized
    /// No HTTP answer at all: connection refused, timed out, host not found, TLS failure…
    /// `message` is a short fixed description; it never contains the URL or the API key.
    case unreachable(String)
    /// Any other non-2xx answer; `message` is the server's `error` text when present.
    case http(status: Int, message: String)
    /// The server answered with something that isn't HTTP.
    case invalidResponse
}

/// `SyncTransport` over the sync server's HTTP API (`/v1`, Bearer-key auth). `baseURL` may carry a
/// path prefix (`https://proxy/sync/`), with or without a trailing slash; every path is appended to it.
public struct HTTPSyncTransport: SyncTransport {
    /// Upper bound for one request, so a hung call can't block the engine's serialized operations forever.
    public static let requestTimeout: TimeInterval = 20

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Builds the request for `path` (e.g. "/v1/vault") under `baseURL`, without doubling the
    /// slash when `baseURL` ends in one. Every request carries the 20 s timeout and, unless
    /// `authenticated` is false, the key.
    func makeRequest(method: String, path: String, query: [(String, String)] = [], body: Data? = nil,
                     authenticated: Bool = true) -> URLRequest {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var string = base + path
        if !query.isEmpty { string += "?" + query.map { "\($0.0)=\($0.1)" }.joined(separator: "&") }
        var request = URLRequest(url: URL(string: string)!)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        if authenticated { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// `GET /health` without the API key: succeeds when a sync server answers at `baseURL`.
    public func health() async throws {
        let (status, data) = try await perform(makeRequest(method: "GET", path: "/health", authenticated: false))
        try check(status, data)
    }

    public func getVault() async throws -> VaultMetadata? {
        let (status, data) = try await send("GET", "/v1/vault")
        if status == 404 { return nil }
        try check(status, data)
        return try CoreJSON.decoder.decode(VaultMetadata.self, from: data)
    }

    public func putVault(_ metadata: VaultMetadata) async throws {
        let (status, data) = try await send("PUT", "/v1/vault", body: metadata)
        if status == 409 { throw SyncError.vaultAlreadyExists }
        try check(status, data)
    }

    public func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata {
        let (status, data) = try await send("POST", "/v1/vault/rewrap", body: request)
        if status == 409 { throw SyncError.vaultChanged }
        if status == 404 { throw SyncError.noVault }
        try check(status, data)
        return try CoreJSON.decoder.decode(VaultMetadata.self, from: data)
    }

    public func fetch(since: Int64, limit: Int) async throws -> RecordsPage {
        let (status, data) = try await send("GET", "/v1/records", query: [("since", "\(since)"), ("limit", "\(limit)")])
        try check(status, data)
        return try CoreJSON.decoder.decode(RecordsPage.self, from: data)
    }

    public func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord] {
        let (status, data) = try await send("POST", "/v1/records", body: UpsertRequest(records: records))
        try check(status, data)
        return try CoreJSON.decoder.decode(UpsertResponse.self, from: data).records
    }

    private func send(_ method: String, _ path: String, query: [(String, String)] = []) async throws -> (Int, Data) {
        try await perform(makeRequest(method: method, path: path, query: query))
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> (Int, Data) {
        try await perform(makeRequest(method: method, path: path, body: try CoreJSON.encoder.encode(body)))
    }

    private func perform(_ request: URLRequest) async throws -> (Int, Data) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SyncTransportError.unreachable(Self.describe(error.code))
        }
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.invalidResponse }
        return (http.statusCode, data)
    }

    private func check(_ status: Int, _ data: Data) throws {
        if let error = Self.statusError(status, data) { throw error }
    }

    /// nil for 2xx; `.unauthorized` for 401/403; otherwise `.http` with the server's `error` text.
    static func statusError(_ status: Int, _ data: Data) -> Error? {
        if (200 ..< 300).contains(status) { return nil }
        if status == 401 || status == 403 { return SyncTransportError.unauthorized }
        struct ErrorBody: Decodable { let error: String }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
        return SyncTransportError.http(status: status, message: message)
    }

    /// A short fixed description of a connection failure (never the URL, which `URLError`'s own
    /// description may include).
    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "the request timed out"
        case .cannotFindHost, .dnsLookupFailed: "the server's name could not be found"
        case .cannotConnectToHost: "the connection was refused"
        case .networkConnectionLost: "the connection was lost"
        case .notConnectedToInternet: "this Mac is offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            "the secure (TLS) connection failed"
        default: "network error \(code.rawValue)"
        }
    }
}
