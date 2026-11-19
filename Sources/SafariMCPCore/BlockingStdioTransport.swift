import Foundation
import Logging
import MCP

/// Newline-delimited JSON-RPC over stdin/stdout, reading with a **blocking** `read`.
///
/// Replaces the SDK's `StdioTransport`, which puts both descriptors in non-blocking mode
/// and, whenever stdin has nothing to say, sleeps 10 ms and tries again — a hundred
/// wakeups a second for as long as the server lives. An MCP server idles almost all of
/// its life, so that loop was the server's whole CPU bill: about 0.6 % of a core, per
/// instance, around the clock. Here one dedicated thread parks in `read(2)` and the
/// kernel wakes it when bytes arrive.
///
/// The one case that still needs a wait is a descriptor that was *inherited* as
/// non-blocking (`EAGAIN`). That wait is `poll(2)` with no timeout, so it also sleeps
/// until the descriptor is ready instead of spinning.
public actor BlockingStdioTransport: Transport {
    public nonisolated let logger: Logger

    private let readBytes: @Sendable (UnsafeMutableRawBufferPointer) -> Int
    private let writeBytes: @Sendable (UnsafeRawBufferPointer) -> Int
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var isConnected = false

    /// `readBytes` and `writeBytes` follow `read(2)` / `write(2)`: bytes transferred, `0`
    /// from a read at end of input, `-1` with `errno` set on failure. They are parameters
    /// so a test can count calls or drive partial writes; production uses the descriptors.
    public init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        readBytes: (@Sendable (UnsafeMutableRawBufferPointer) -> Int)? = nil,
        writeBytes: (@Sendable (UnsafeRawBufferPointer) -> Int)? = nil
    ) {
        self.readBytes = readBytes ?? { Self.read(input, into: $0) }
        self.writeBytes = writeBytes ?? { Self.write(output, from: $0) }
        // A no-op handler, as in the SDK's own transport: a logger on stdout would
        // interleave with the JSON-RPC stream.
        self.logger = Logger(label: "mcp.transport.blocking-stdio") { _ in
            SwiftLogNoOpLogHandler()
        }

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        let readBytes = self.readBytes
        let continuation = self.messageContinuation
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var pending = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes { readBytes($0) }
                // End of input (the host closed the pipe) or a read failure both end the
                // stream, which is what lets the server finish and the process exit.
                if count <= 0 { break }
                pending.append(contentsOf: buffer[..<count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { continuation.yield(line) }
                }
            }
            continuation.finish()
        }
        reader.name = "stdin-reader"
        reader.start()
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    public func send(_ message: Data) async throws {
        guard isConnected else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }

        var remaining = message
        remaining.append(UInt8(ascii: "\n"))
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { writeBytes($0) }
            guard written > 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw MCPError.transportError(POSIXError(code))
            }
            remaining.removeFirst(written)
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: Descriptors

    private static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer)
        -> Int
    {
        while true {
            let count = Foundation.read(descriptor, buffer.baseAddress, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            if errno == EAGAIN { awaitReady(descriptor, events: Int16(POLLIN)); continue }
            return -1
        }
    }

    private static func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) -> Int {
        while true {
            let count = Foundation.write(descriptor, buffer.baseAddress, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            if errno == EAGAIN { awaitReady(descriptor, events: Int16(POLLOUT)); continue }
            return -1
        }
    }

    /// Sleeps in the kernel until the descriptor can be read or written. No timeout: the
    /// whole point is that an idle server does nothing.
    private static func awaitReady(_ descriptor: Int32, events: Int16) {
        var request = pollfd(fd: descriptor, events: events, revents: 0)
        while poll(&request, 1, -1) < 0 && errno == EINTR {}
    }
}
