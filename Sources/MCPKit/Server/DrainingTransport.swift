import Foundation
import JSONRPCKit
import Synchronization

/// Internal `Transport` wrapper used by ``Server`` so a connection is not declared
/// terminated until every request received before the end of the message stream has
/// been answered.
///
/// `JSONRPCPeer` answers incoming requests from detached tasks, so "the message
/// stream ended" does not imply "responses were written": a client that pipelines a
/// batch of requests and closes its end of the pipe immediately would otherwise lose
/// every response. This wrapper counts incoming requests and outgoing responses (both
/// observable on the wire) and lets the server wait for the counts to converge.
final class DrainingTransport: Transport, @unchecked Sendable {
    private let base: any Transport

    let messages: AsyncStream<Data>
    private let messagesContinuation: AsyncStream<Data>.Continuation

    private let mutex = Mutex<Counts>(Counts())
    private struct Counts {
        var incomingRequests = 0
        var outgoingResponses = 0
    }

    private var forwardTask: Task<Void, Never>?

    init(base: any Transport) {
        self.base = base
        var continuation: AsyncStream<Data>.Continuation!
        self.messages = AsyncStream { continuation = $0 }
        self.messagesContinuation = continuation
    }

    var state: AsyncStream<TransportState> { base.state }

    func start() async throws {
        try await base.start()
        let baseMessages = base.messages
        forwardTask = Task { [weak self] in
            for await data in baseMessages {
                guard let self else { return }
                self.noteIncoming(data)
                self.messagesContinuation.yield(data)
            }
            // Finishing here delivers every buffered message to the peer's dispatch
            // loop before its own iteration ends.
            self?.messagesContinuation.finish()
        }
    }

    func send(_ data: Data) async throws {
        noteOutgoing(data)
        try await base.send(data)
    }

    func close() async {
        forwardTask?.cancel()
        await base.close()
    }

    // MARK: - Counting

    private func noteIncoming(_ data: Data) {
        guard let message = try? JSONRPCMessage(data: data), case .request = message else { return }
        mutex.withLock { $0.incomingRequests += 1 }
    }

    private func noteOutgoing(_ data: Data) {
        guard let message = try? JSONRPCMessage(data: data) else { return }
        switch message {
        case .response, .error:
            mutex.withLock { $0.outgoingResponses += 1 }
        case .request, .notification:
            break
        }
    }

    // MARK: - Termination

    /// Waits until the base transport's message stream has ended (EOF) and every
    /// request forwarded before the end has received a response, then returns.
    ///
    /// Returns early when the calling task is cancelled (forced shutdown via
    /// `close()`) or when `drainTimeout` elapses (a handler that never returns).
    func waitForTermination(drainTimeout: TimeInterval) async {
        // The forwarding task completes only after the base stream ended and every
        // buffered message was forwarded (and counted).
        await forwardTask?.value
        let deadline = ContinuousClock.now + .seconds(max(drainTimeout, 0.001))
        while true {
            if Task.isCancelled { return }
            if mutex.withLock({ $0.outgoingResponses >= $0.incomingRequests }) { return }
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
