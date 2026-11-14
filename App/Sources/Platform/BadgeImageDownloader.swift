import Foundation
import AppCore

/// Downloads a badge image for Settings → OS Icons: http/https only (checked before calling),
/// an ephemeral session (no cookies, cache or credentials), a 15 s timeout and a 2 MB limit,
/// checked against Content-Length when the server sends one and while receiving. The bytes are
/// only ever handed to the image decoder.
enum BadgeImageDownloader {
    static func download(from url: URL) async throws(BadgeImageError) -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = BadgeImageRules.downloadTimeout
        configuration.timeoutIntervalForResource = BadgeImageRules.downloadTimeout
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse,
               let problem = BadgeImageRules.problem(httpStatus: http.statusCode) {
                throw problem
            }
            if let problem = BadgeImageRules.problem(contentLength: response.expectedContentLength) {
                throw problem
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                data.append(byte)
                if BadgeImageRules.exceedsLimit(byteCount: data.count) {
                    throw BadgeImageError.tooLarge
                }
            }
            return data
        } catch let error as BadgeImageError {
            throw error
        } catch is CancellationError {
            throw .downloadFailed("the download was cancelled.")
        } catch {
            throw .downloadFailed(error.localizedDescription)
        }
    }
}
