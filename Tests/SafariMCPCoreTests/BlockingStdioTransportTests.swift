import Foundation
import MCP
import Testing

@testable import SafariMCPCore

/// Every descriptor here is a pipe the test made; nothing touches Safari, and the server
/// under test is driven by `FakeSafariStore`.
@Suite("Blocking stdio transport")
struct BlockingStdioTransportTests {

    /// Counts calls from another thread. A class with a lock, because the reader thread
    /// and the test body both touch it.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func messages(_ transport: BlockingStdioTransport, count: Int) async throws
        -> [String]
    {
        var collected: [String] = []
        for try await message in await transport.receive() {
            collected.append(String(decoding: message, as: UTF8.self))
            if collected.count == count { break }
        }
        return collected
    }

    @Test("An idle reader parks in one read instead of polling")
    func idleReaderDoesNotPoll() async throws {
        // The regression: the SDK transport slept 10 ms and re-read on every empty
        // read — a hundred calls a second while idle. A blocking reader calls once and
        // waits, so 300 ms of silence must still be exactly one call.
        let reads = Counter()
        let release = DispatchSemaphore(value: 0)
        let transport = BlockingStdioTransport(readBytes: { _ in
            reads.increment()
            release.wait()
            return 0
        })
        try await transport.connect()

        try await Task.sleep(for: .milliseconds(300))
        #expect(reads.count == 1)

        release.signal()
        for try await _ in await transport.receive() {}
    }

    @Test("Messages split across reads, and several in one read, all arrive whole")
    func framesLines() async throws {
        let pipe = Pipe()
        let transport = BlockingStdioTransport(input: pipe.fileHandleForReading.fileDescriptor)
        try await transport.connect()

        let writer = pipe.fileHandleForWriting
        try writer.write(contentsOf: Data("{\"a\":1}\n{\"b\"".utf8))
        try await Task.sleep(for: .milliseconds(50))
        try writer.write(contentsOf: Data(":2}\n\n{\"c\":3}\n".utf8))

        let received = try await messages(transport, count: 3)
        #expect(received == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    @Test("The descriptors are left in blocking mode")
    func leavesBlockingModeAlone() async throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let transport = BlockingStdioTransport(input: descriptor)
        try await transport.connect()
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
    }

    @Test("End of input finishes the stream, so the server can exit")
    func endOfInputFinishesStream() async throws {
        let pipe = Pipe()
        let transport = BlockingStdioTransport(input: pipe.fileHandleForReading.fileDescriptor)
        try await transport.connect()
        try pipe.fileHandleForWriting.close()

        var count = 0
        for try await _ in await transport.receive() { count += 1 }
        #expect(count == 0)
    }

    @Test("A message is sent whole, newline-terminated, even when writes are partial")
    func sendsAcrossPartialWrites() async throws {
        let sink = Sink()
        let transport = BlockingStdioTransport(
            readBytes: { _ in 0 },
            writeBytes: { buffer in
                let accepted = min(3, buffer.count)
                sink.append(Data(buffer.prefix(accepted)))
                return accepted
            })
        try await transport.connect()

        try await transport.send(Data("{\"id\":1}".utf8))
        #expect(String(decoding: sink.data, as: UTF8.self) == "{\"id\":1}\n")
    }

    @Test("Sending before connecting fails instead of writing")
    func sendRequiresConnection() async {
        let sink = Sink()
        let transport = BlockingStdioTransport(
            readBytes: { _ in 0 },
            writeBytes: { buffer in
                sink.append(Data(buffer))
                return buffer.count
            })
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
        #expect(sink.data.isEmpty)
    }

    @Test("The whole server answers initialize over the transport")
    func serverAnswersOverPipes() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let transport = BlockingStdioTransport(
            input: toServer.fileHandleForReading.fileDescriptor,
            output: fromServer.fileHandleForWriting.fileDescriptor)

        let server = Task {
            try await SafariMCPServer.run(
                store: FakeSafariStore(), configuration: Configuration(), transport: transport)
        }

        let request = """
            {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
            """
        try toServer.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))

        // Read on a thread of its own: `availableData` blocks, and a server that never
        // answers must fail this test rather than hang it.
        let reply = Task.detached { fromServer.fileHandleForReading.availableData }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            try fromServer.fileHandleForWriting.close()
        }
        let text = String(decoding: await reply.value, as: UTF8.self)
        timeout.cancel()

        #expect(text.contains("\"id\":0"))
        #expect(text.contains(SafariMCPServer.name))
        #expect(text.contains(SafariMCPServer.version))

        try toServer.fileHandleForWriting.close()
        _ = try? await server.value
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        var data: Data { lock.withLock { bytes } }
    }
}
