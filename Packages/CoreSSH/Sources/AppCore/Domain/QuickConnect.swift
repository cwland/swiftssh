import Foundation

public struct QuickConnectTarget: Equatable, Sendable {
    public var username: String?
    public var host: String
    public var port: Int?

    public init(username: String?, host: String, port: Int?) {
        self.username = username; self.host = host; self.port = port
    }
}

public enum QuickConnect {
    /// Parses `[ssh] [-l user] [-p port] [user@]host[:port]`. Bare IPv6 (`fe80::1`) is a host
    /// without a port; use brackets (`[fe80::1]:22`) to give one. Returns nil for empty input,
    /// unknown options, missing option values or ports outside 1...65535.
    public static func parse(_ input: String) -> QuickConnectTarget? {
        var tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1, tokens[0] == "ssh" { tokens.removeFirst() }

        var positional: String?
        var optionUser: String?
        var optionPort: Int?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case "-p":
                guard index < tokens.count, let port = parsePort(tokens[index]) else { return nil }
                optionPort = port
                index += 1
            case "-l":
                guard index < tokens.count else { return nil }
                optionUser = tokens[index]
                index += 1
            default:
                guard !token.hasPrefix("-"), positional == nil else { return nil }
                positional = token
            }
        }
        guard var rest = positional else { return nil }

        var user = optionUser
        if let at = rest.lastIndex(of: "@") {
            let name = String(rest[..<at])
            guard !name.isEmpty else { return nil }
            user = name
            rest = String(rest[rest.index(after: at)...])
        }
        if user?.isEmpty == true { return nil }

        var host = rest
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":"), let parsed = parsePort(String(tail.dropFirst())) else { return nil }
                port = parsed
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            guard let parsed = parsePort(String(rest[rest.index(after: colon)...])) else { return nil }
            port = parsed
        }
        guard !host.isEmpty else { return nil }
        return QuickConnectTarget(username: user, host: host, port: optionPort ?? port)
    }

    private static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }
}
