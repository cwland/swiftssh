import Foundation
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
#endif

/// A minimal HTTP/1.1 server on 127.0.0.1 (random port) for transport tests. Each connection gets
/// one canned response; the raw request heads it received are recorded.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var _requests: [String] = []
    private let respond: @Sendable (String) -> String

    /// The request heads (request line + headers) received so far.
    var requests: [String] { lock.withLock { _requests } }

    init(respond: @escaping @Sendable (_ requestHead: String) -> String) throws {
        self.respond = respond
        let fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        self.port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var head = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !head.contains("\r\n\r\n".data(using: .utf8)!) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                head.append(buffer, count: count)
            }
            let text = String(decoding: head, as: UTF8.self)
            lock.withLock { _requests.append(text) }
            let response = Array(respond(text).utf8)
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
