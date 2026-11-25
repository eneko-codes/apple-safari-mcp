import Darwin
import Foundation
import Testing

@testable import SafariMCPCore

/// The stdio side of the server: `serve` reading a pipe through `FileHandle.bytes.lines`,
/// the same reader `serveStandardStreams` puts on stdin. Every descriptor is a pipe the
/// test made. Nothing touches Safari: the in-process server runs on `FakeSafariStore`, and
/// the spawned one is sent no request at all.
@Suite("Standard streams")
struct StandardStreamsTests {

    /// Collects replies from the concurrent tasks `serve` answers on.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [String] = []
        func append(_ line: String) { lock.withLock { collected.append(line) } }
        var lines: [String] { lock.withLock { collected } }
    }

    private func serve(_ pipe: Pipe, into sink: Sink) -> Task<Void, Never> {
        let handler = SafariMCPServer.handler(
            tools: SafariTools(store: FakeSafariStore()), configuration: Configuration())
        let input = pipe.fileHandleForReading
        return Task { await SafariMCPCore.serve(lines: input.bytes.lines, handler: handler, write: sink.append) }
    }

    @Test("An idle server sleeps instead of polling")
    func idleServerDoesNotPoll() async throws {
        // The regression: the SDK transport slept 10 ms and re-read on every empty read —
        // a hundred wakeups a second while idle. The built server is started with stdin
        // open and silent, so it must sit in the kernel without waking.
        // SwiftPM puts the test bundle next to the executables it built.
        let products = Bundle(for: Sink.self).bundleURL.deletingLastPathComponent()
        let input = Pipe()
        let server = Process()
        server.executableURL = products.appending(path: SafariMCPServer.name)
        server.standardInput = input
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()

        try await Task.sleep(for: .milliseconds(300))
        let before = try wakeups(server.processIdentifier)
        try await Task.sleep(for: .seconds(1))
        let after = try wakeups(server.processIdentifier)
        #expect(after - before < 20, "\(after - before) wakeups in one idle second")

        // End of input is how the host stops the server; it must exit rather than linger.
        try input.fileHandleForWriting.close()
        server.waitUntilExit()
        #expect(server.terminationStatus == 0)
    }

    private func wakeups(_ process: pid_t) throws -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process, RUSAGE_INFO_V4, $0)
            }
        }
        try #require(status == 0)
        return usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
    }

    @Test("Messages split across writes, and several in one write, are all answered")
    func framesLines() async throws {
        let pipe = Pipe()
        let sink = Sink()
        let served = serve(pipe, into: sink)

        let writer = pipe.fileHandleForWriting
        try writer.write(contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n").utf8))
        try writer.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":2,"#.utf8))
        try await Task.sleep(for: .milliseconds(50))
        try writer.write(
            contentsOf: Data(
                (#""method":"ping"}"# + "\n\n" + #"{"jsonrpc":"2.0","id":3,"method":"ping"}"# + "\n").utf8))
        try writer.close()
        await served.value

        let ids = try sink.lines.map { line in
            try #require(try JSONDecoder().decode(Value.self, from: Data(line.utf8)).objectValue?["id"])
        }
        #expect(Set(ids) == [1, 2, 3])
        #expect(ids.count == 3)
    }

    @Test("The input descriptor is left in blocking mode")
    func leavesBlockingModeAlone() async throws {
        let pipe = Pipe()
        let served = serve(pipe, into: Sink())
        try await Task.sleep(for: .milliseconds(100))
        #expect(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL) & O_NONBLOCK == 0)
        try pipe.fileHandleForWriting.close()
        await served.value
    }

    @Test("End of input ends serving, so the server can exit")
    func endOfInputFinishesServing() async throws {
        let pipe = Pipe()
        let sink = Sink()
        let served = serve(pipe, into: sink)
        try pipe.fileHandleForWriting.close()
        await served.value
        #expect(sink.lines.isEmpty)
    }

    @Test("The whole server answers initialize over a pipe")
    func serverAnswersOverPipe() async throws {
        let pipe = Pipe()
        let sink = Sink()
        let served = serve(pipe, into: sink)

        let request = """
            {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
            """
        try pipe.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        await served.value

        let text = sink.lines.joined()
        #expect(text.contains("\"id\":0"))
        #expect(text.contains(SafariMCPServer.name))
        #expect(text.contains(SafariMCPServer.version))
    }
}
