import Foundation
import XCTest
@testable import SSHCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class PTYProcessTests: XCTestCase {
    func testRunsCommandAndCollectsOutput() async throws {
        let process = try PTYProcess(executable: "/bin/echo", arguments: ["hello"], environment: [:], cols: 80, rows: 24)
        let output = await collect(process)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("hello\r\n"))
        XCTAssertEqual(process.exitStatus, 0)
    }

    func testWriteAndResize() async throws {
        // The script waits for a first line so the resize is guaranteed to land before `stty size`.
        let process = try PTYProcess(executable: "/bin/sh",
                                     arguments: ["-c", "read go; stty size; read x; echo got:$x"],
                                     environment: [:], cols: 80, rows: 24)
        let recorder = ByteRecorder(process.output)
        process.resize(cols: 90, rows: 30)
        process.write(Array("go\n".utf8))
        try await waitUntil { recorder.text.contains("30 90") }
        process.write(Array("z\n".utf8))
        try await waitUntil { recorder.finished }
        XCTAssertTrue(recorder.text.contains("got:z"), recorder.text)
        XCTAssertEqual(process.exitStatus, 0)
    }

    func testTerminateEndsStream() async throws {
        let process = try PTYProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:], cols: 80, rows: 24)
        let recorder = ByteRecorder(process.output)
        let started = Date()
        process.terminate()
        try await waitUntil(timeout: 5) { recorder.finished }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(process.exitStatus, 128 + SIGHUP)
    }

    func testTerminateKillsProcessIgnoringHangup() async throws {
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "trap '' HUP; echo ready; sleep 30"],
                                     environment: [:], cols: 80, rows: 24)
        let recorder = ByteRecorder(process.output)
        try await waitUntil { recorder.text.contains("ready") }
        process.terminate()
        try await waitUntil(timeout: 6) { recorder.finished }
        XCTAssertEqual(process.exitStatus, 128 + SIGKILL)
    }

    func testTerminateWhileAWriteIsBlocked() async throws {
        // The child never reads, so a large write fills the terminal's input buffer and cannot finish. (In
        // canonical mode Linux drops input beyond its line buffer instead of blocking, so use raw mode.)
        let process = try PTYProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:], cols: 80, rows: 24,
                                     rawMode: true)
        let recorder = ByteRecorder(process.output)
        let writing = Task.detached { process.write([UInt8](repeating: UInt8(ascii: "x"), count: 1_048_576)) }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        let terminated = TestFlag()
        Task.detached {
            process.terminate()
            process.resize(cols: 100, rows: 30) // must not wait for the writer either
            terminated.set()
        }
        try await waitUntil(timeout: 3) { terminated.value && recorder.finished }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        await writing.value // the blocked write gives up once the child is gone
        XCTAssertEqual(process.exitStatus, 128 + SIGHUP)
    }

    func testCanonicalModeIsReported() async throws {
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "read a; stty raw -echo; echo raw; read b"],
                                     environment: [:], cols: 80, rows: 24)
        let recorder = ByteRecorder(process.output)
        XCTAssertEqual(process.terminalMode, .canonical)
        process.write(Array("go\n".utf8))
        try await waitUntil { recorder.text.contains("raw") }
        XCTAssertEqual(process.terminalMode, .raw)
        process.terminate()
        try await waitUntil(timeout: 5) { recorder.finished }
        XCTAssertEqual(process.terminalMode, .exited)
    }

    func testEnvironmentIsOnlyTheGivenOnesPlusBasics() async throws {
        setenv("TR_PARENT_ONLY_VARIABLE", "leak", 1)
        defer { unsetenv("TR_PARENT_ONLY_VARIABLE") }
        let process = try PTYProcess(executable: "/usr/bin/env", arguments: [], environment: ["TR_GIVEN": "yes"],
                                     cols: 80, rows: 24)
        let text = String(decoding: await collect(process), as: UTF8.self)
        let names = Set(text.components(separatedBy: "\r\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        XCTAssertTrue(text.contains("TR_GIVEN=yes"), text)
        XCTAssertTrue(text.contains("TERM=xterm-256color"), text)
        XCTAssertFalse(text.contains("TR_PARENT_ONLY_VARIABLE"), text)
        XCTAssertTrue(names.isSubset(of: ["TR_GIVEN", "TERM", "PATH", "HOME", "USER", "LANG"]), "\(names)")
    }

    func testTerminalTypeSetsTERM() async throws {
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "echo term=$TERM"], environment: [:],
                                     terminalType: .vt100, cols: 80, rows: 24)
        let text = String(decoding: await collect(process), as: UTF8.self)
        XCTAssertTrue(text.contains("term=vt100\r\n"), text)
    }

    #if os(Linux)
    func testChildDoesNotInheritOpenDescriptors() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0) // not close-on-exec
        defer { close(fds[0]); close(fds[1]) }
        let process = try PTYProcess(executable: "/bin/ls", arguments: ["/proc/self/fd"], environment: [:], cols: 80, rows: 24)
        let text = String(decoding: await collect(process), as: UTF8.self)
        let listed = Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        XCTAssertGreaterThan(fds[1], 3)
        // Only stdio and the directory descriptor ls opens itself.
        XCTAssertTrue(listed.isSubset(of: ["0", "1", "2", "3"]), "leaked descriptors: \(listed)")
    }
    #endif

    func testSignalDispositionsAreReset() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        // `yes | head -1`: yes must die of SIGPIPE (default disposition) rather than loop on EPIPE.
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "yes | head -1; echo done"],
                                     environment: [:], cols: 80, rows: 24)
        let recorder = ByteRecorder(process.output)
        try await waitUntil(timeout: 5) { recorder.finished }
        XCTAssertTrue(recorder.text.contains("done"))
    }

    private func collect(_ process: PTYProcess) async -> [UInt8] {
        var bytes: [UInt8] = []
        for await chunk in process.output { bytes.append(contentsOf: chunk) }
        return bytes
    }
}

/// Collects a byte stream in the background.
final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var done = false

    init(_ stream: AsyncStream<[UInt8]>) {
        Task {
            for await chunk in stream { self.lock.withLock { self.bytes.append(contentsOf: chunk) } }
            self.lock.withLock { self.done = true }
        }
    }

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var finished: Bool { lock.withLock { done } }
}
