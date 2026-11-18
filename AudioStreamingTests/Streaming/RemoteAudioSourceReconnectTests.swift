//
//  RemoteAudioSourceReconnectTests.swift
//  AudioStreamingTests
//

import Foundation
import Network
import XCTest
@testable import AudioStreaming

/// A tiny local HTTP server that streams bytes forever, like an Icecast mount,
/// and can drop each connection after a set number of chunks.
private final class LocalLiveStreamServer {
    enum Drop {
        /// The server closes the connection cleanly (FIN): the client sees a normal end.
        case clean
        /// The connection is torn down abruptly: the client sees a transport error.
        case abrupt
    }

    struct Request {
        let head: String
        let receivedAt: DispatchTime
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.live.stream.server")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var connections: [NWConnection] = []
    private let contentLength: Int?
    /// Number of chunks to send on each streaming connection before dropping it, by connection index.
    private let chunksBeforeDrop: (Int) -> Int?
    private let drop: Drop
    private var streamingConnectionIndex = 0

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(drop: Drop, contentLength: Int? = nil, chunksBeforeDrop: @escaping (Int) -> Int?) throws {
        self.drop = drop
        self.contentLength = contentLength
        self.chunksBeforeDrop = chunksBeforeDrop
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { return }
            self.lock.lock()
            self._requests.append(Request(head: head, receivedAt: .now()))
            self.lock.unlock()

            var header = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nServer: Icecast 2.4.4\r\nicy-name: Test\r\nCache-Control: no-cache\r\n"
            if let contentLength = self.contentLength {
                header += "Content-Length: \(contentLength)\r\n"
            }
            header += "Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

            // The source's first open sends a short probe (Range: bytes=0-1) and
            // cancels it; only full requests count as streaming connections.
            let isProbe = head.contains("Range: bytes=0-1")
            let limit: Int?
            if isProbe {
                limit = nil
            } else {
                self.lock.lock()
                let index = self.streamingConnectionIndex
                self.streamingConnectionIndex += 1
                self.lock.unlock()
                limit = self.chunksBeforeDrop(index)
            }
            self.sendChunks(on: connection, sent: 0, limit: limit)
        }
    }

    private func sendChunks(on connection: NWConnection, sent: Int, limit: Int?) {
        if let limit, sent >= limit {
            switch drop {
            case .clean:
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            case .abrupt:
                connection.forceCancel()
            }
            return
        }
        let chunk = Data(repeating: 0x55, count: 4096)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                self?.sendChunks(on: connection, sent: sent + 1, limit: limit)
            }
        })
    }
}

private final class SourceDelegateSpy: AudioStreamSourceDelegate {
    private let lock = NSLock()
    private(set) var bytes = 0
    private(set) var endOfFileCount = 0
    private(set) var errors: [Error] = []
    var onEndOfFile: (() -> Void)?

    func dataAvailable(source _: CoreAudioStreamSource, data: Data) {
        lock.lock(); bytes += data.count; lock.unlock()
    }

    func errorOccurred(source _: CoreAudioStreamSource, error: Error) {
        lock.lock(); errors.append(error); lock.unlock()
    }

    func endOfFileOccurred(source _: CoreAudioStreamSource) {
        lock.lock(); endOfFileCount += 1; lock.unlock()
        onEndOfFile?()
    }

    func metadataReceived(data _: [String: String]) {}
}

final class RemoteAudioSourceReconnectTests: XCTestCase {
    private var server: LocalLiveStreamServer?
    private var source: RemoteAudioSource?

    override func tearDown() {
        source?.close()
        server?.stop()
        source = nil
        server = nil
        super.tearDown()
    }

    private func makeSource(port: UInt16, delegate: SourceDelegateSpy) -> RemoteAudioSource {
        let source = RemoteAudioSource(
            networking: NetworkingClient(),
            url: URL(string: "http://127.0.0.1:\(port)/live")!,
            underlyingQueue: DispatchQueue(label: "test.remote.source")
        )
        source.delegate = delegate
        // Treat a connection as healthy after a fraction of a second so the test stays fast.
        source.healthyConnectionSeconds = 0.2
        return source
    }

    private func streamingRequests(_ server: LocalLiveStreamServer) -> [LocalLiveStreamServer.Request] {
        server.requests.filter { !$0.head.contains("Range: bytes=0-1") }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A live stream whose connection is closed cleanly after it has been
    /// playing (as happens on a network handover) is reopened right away,
    /// without the probe request, and is not reported as the end of the file.
    func testCleanlyClosedLiveStreamReconnectsImmediately() throws {
        // First streaming connection: about 0.4 s of data, then a clean close.
        let server = try LocalLiveStreamServer(drop: .clean) { index in index == 0 ? 20 : nil }
        self.server = server
        server.start()

        let spy = SourceDelegateSpy()
        let source = makeSource(port: server.port, delegate: spy)
        self.source = source
        source.seek(at: 0)

        waitUntil(timeout: 5) { streamingRequests(server).count >= 2 }

        let streaming = streamingRequests(server)
        XCTAssertEqual(streaming.count, 2, "the live stream should be reopened after the clean close")
        XCTAssertEqual(spy.endOfFileCount, 0, "a live stream ending is a lost connection, not end of file")
        XCTAssertTrue(spy.errors.isEmpty)

        // The reopen should not pay for the retrier's one second delay.
        let gapNanos = streaming[1].receivedAt.uptimeNanoseconds - streaming[0].receivedAt.uptimeNanoseconds
        let expectedFirstConnectionNanos: UInt64 = 20 * 20_000_000
        XCTAssertLessThan(gapNanos, expectedFirstConnectionNanos + 600_000_000)

        // A reopen with known headers goes straight to the stream: one probe in total.
        let probes = server.requests.filter { $0.head.contains("Range: bytes=0-1") }
        XCTAssertEqual(probes.count, 1)

        let bytesBefore = spy.bytes
        waitUntil(timeout: 2) { spy.bytes > bytesBefore }
        XCTAssertGreaterThan(spy.bytes, bytesBefore, "audio keeps flowing from the new connection")
    }

    /// The same for a transport error (connection reset), e.g. Wi-Fi going away.
    func testAbruptlyDroppedLiveStreamReconnectsImmediately() throws {
        let server = try LocalLiveStreamServer(drop: .abrupt) { index in index == 0 ? 20 : nil }
        self.server = server
        server.start()

        let spy = SourceDelegateSpy()
        let source = makeSource(port: server.port, delegate: spy)
        self.source = source
        source.seek(at: 0)

        waitUntil(timeout: 5) { streamingRequests(server).count >= 2 }

        let streaming = streamingRequests(server)
        XCTAssertEqual(streaming.count, 2)
        XCTAssertEqual(spy.endOfFileCount, 0)
        let gapNanos = streaming[1].receivedAt.uptimeNanoseconds - streaming[0].receivedAt.uptimeNanoseconds
        XCTAssertLessThan(gapNanos, 20 * 20_000_000 + 600_000_000)
    }

    /// A server that keeps cutting us off right away is not reconnected forever:
    /// after the allowed rapid reconnects the clean end is reported as before.
    func testRepeatedShortLivedLiveConnectionsEventuallyEnd() throws {
        let server = try LocalLiveStreamServer(drop: .clean) { _ in 2 }
        self.server = server
        server.start()

        let spy = SourceDelegateSpy()
        let source = makeSource(port: server.port, delegate: spy)
        source.healthyConnectionSeconds = 60
        self.source = source
        source.seek(at: 0)

        waitUntil(timeout: 5) { spy.endOfFileCount > 0 }

        XCTAssertEqual(spy.endOfFileCount, 1)
        XCTAssertEqual(streamingRequests(server).count, 1 + source.maxRapidReconnects)
    }

    /// A finite file (known length) still ends normally.
    func testFiniteFileStillReportsEndOfFile() throws {
        let length = 10 * 4096
        let server = try LocalLiveStreamServer(drop: .clean, contentLength: length) { _ in 10 }
        self.server = server
        server.start()

        let spy = SourceDelegateSpy()
        let source = makeSource(port: server.port, delegate: spy)
        self.source = source
        source.seek(at: 0)

        waitUntil(timeout: 5) { spy.endOfFileCount > 0 }

        XCTAssertEqual(spy.endOfFileCount, 1)
        XCTAssertEqual(streamingRequests(server).count, 1)
    }
}
