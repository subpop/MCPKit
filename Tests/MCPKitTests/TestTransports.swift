import Foundation
import JSONRPCKit
import Synchronization

@testable import MCPKit

/// In-memory transport that captures outbound payloads and lets tests inject
/// inbound ones. Used for handler-dispatch tests against `Server`.
final class CapturingTransport: Transport, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let incoming: AsyncStream<Data>.Continuation
    let state: AsyncStream<TransportState>
    private let stateContinuation: AsyncStream<TransportState>.Continuation

    private let sentMutex = Mutex<[Data]>([])
    var sent: [Data] { sentMutex.withLock { $0 } }

    init() {
        var incoming: AsyncStream<Data>.Continuation!
        self.messages = AsyncStream { incoming = $0 }
        self.incoming = incoming
        var stateContinuation: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { stateContinuation = $0 }
        self.stateContinuation = stateContinuation
    }

    func start() async throws {
        stateContinuation.yield(.started)
    }

    func send(_ data: Data) async throws {
        sentMutex.withLock { $0.append(data) }
    }

    func inject(_ data: Data) {
        incoming.yield(data)
    }

    func finish() {
        incoming.finish()
    }

    func close() async {
        incoming.finish()
    }

    /// Decodes every captured outbound payload as a JSON-RPC message.
    var sentMessages: [JSONRPCMessage] {
        sent.compactMap { try? JSONRPCMessage(data: $0) }
    }

    /// Returns the first outbound response (or error) with the given request id,
    /// or `nil` if none has been written yet.
    func response(for id: RequestID) -> JSONRPCMessage? {
        sentMessages.first { message in
            switch message {
            case .response(let response): return response.id == id
            case .error(let error): return error.id == id
            default: return false
            }
        }
    }

    /// Waits until an outbound payload matching `predicate` has been written.
    func awaitSent(
        matching predicate: @escaping @Sendable (Data) -> Bool,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            for data in sent where predicate(data) {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TableTestError.timedOut
    }
}

/// In-memory transport that auto-answers incoming requests via `handler`, with an
/// optional `sideEffect` hook invoked after the request is captured but before the
/// response is delivered (used to inject server-initiated traffic mid-request, e.g.
/// `notifications/progress`). Used for outgoing-call tests against `Client`.
final class AutoRespondingTransport: Transport, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let incoming: AsyncStream<Data>.Continuation
    let state: AsyncStream<TransportState>
    private let stateContinuation: AsyncStream<TransportState>.Continuation

    private let sentMutex = Mutex<[Data]>([])
    var sent: [Data] { sentMutex.withLock { $0 } }

    var handler: @Sendable (String, JSONValue?) throws -> JSONValue = { _, _ in .object([:]) }
    var sideEffect: (@Sendable () async -> Void)?

    init() {
        var incoming: AsyncStream<Data>.Continuation!
        self.messages = AsyncStream { incoming = $0 }
        self.incoming = incoming
        var stateContinuation: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { stateContinuation = $0 }
        self.stateContinuation = stateContinuation
    }

    func start() async throws {
        stateContinuation.yield(.started)
    }

    func send(_ data: Data) async throws {
        sentMutex.withLock { $0.append(data) }
        let message = try JSONRPCMessage(data: data)
        guard case .request(let request) = message else { return }
        if let sideEffect {
            await sideEffect()
        }
        let result = try handler(request.method, request.params)
        let response = try JSONRPCMessage.response(
            JSONRPCResponse(id: request.id, result: result)
        ).encoded()
        incoming.yield(response)
    }

    func inject(_ data: Data) {
        incoming.yield(data)
    }

    func close() async {
        incoming.finish()
    }

    /// Decodes every captured outbound payload as a JSON-RPC message.
    var sentMessages: [JSONRPCMessage] {
        sent.compactMap { try? JSONRPCMessage(data: $0) }
    }

    /// Returns the first outbound response (or error) with the given request id,
    /// or `nil` if none has been written yet.
    func response(for id: RequestID) -> JSONRPCMessage? {
        sentMessages.first { message in
            switch message {
            case .response(let response): return response.id == id
            case .error(let error): return error.id == id
            default: return false
            }
        }
    }

    /// Waits until an outbound payload matching `predicate` has been written.
    func awaitSent(
        matching predicate: @escaping @Sendable (Data) -> Bool,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            for data in sent where predicate(data) {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TableTestError.timedOut
    }
}

/// Bidirectional in-memory pair. `send` on one end appears in the other's
/// `messages`. Used for client↔server round-trip tests.
///
/// The pair is cross-wired at creation: each end holds its own `messages`
/// stream plus the partner's incoming continuation, so `send` needs no
/// shared mutable state (and no lock).
final class LoopbackTransport: Transport, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let outgoing: AsyncStream<Data>.Continuation
    let state: AsyncStream<TransportState>
    private let stateContinuation: AsyncStream<TransportState>.Continuation

    fileprivate init(
        messages: AsyncStream<Data>,
        outgoing: AsyncStream<Data>.Continuation,
        state: AsyncStream<TransportState>,
        stateContinuation: AsyncStream<TransportState>.Continuation
    ) {
        self.messages = messages
        self.outgoing = outgoing
        self.state = state
        self.stateContinuation = stateContinuation
    }

    func start() async throws {
        stateContinuation.yield(.started)
    }

    func send(_ data: Data) async throws {
        outgoing.yield(data)
    }

    func close() async {}
}

func makeLoopbackPair() -> (LoopbackTransport, LoopbackTransport) {
    var incomingA: AsyncStream<Data>.Continuation!
    let messagesA = AsyncStream<Data> { incomingA = $0 }
    var incomingB: AsyncStream<Data>.Continuation!
    let messagesB = AsyncStream<Data> { incomingB = $0 }
    var stateContinuationA: AsyncStream<TransportState>.Continuation!
    let stateA = AsyncStream<TransportState> { stateContinuationA = $0 }
    var stateContinuationB: AsyncStream<TransportState>.Continuation!
    let stateB = AsyncStream<TransportState> { stateContinuationB = $0 }
    let a = LoopbackTransport(
        messages: messagesA, outgoing: incomingB,
        state: stateA, stateContinuation: stateContinuationA)
    let b = LoopbackTransport(
        messages: messagesB, outgoing: incomingA,
        state: stateB, stateContinuation: stateContinuationB)
    return (a, b)
}

enum TableTestError: Error {
    case timedOut
}

/// Encodes a JSON-RPC request for injection.
func rpcRequestData(id: RequestID, method: String, params: JSONValue? = nil) throws -> Data {
    try JSONRPCMessage.request(JSONRPCRequest(id: id, method: method, params: params)).encoded()
}

/// Encodes a JSON-RPC notification for injection.
func rpcNotificationData(method: String, params: JSONValue? = nil) throws -> Data {
    try JSONRPCMessage.notification(JSONRPCNotification(method: method, params: params)).encoded()
}

/// Parses a JSON object from a string literal, for expected-wire-value tables.
func jsonObject(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}

/// Predicate matching a response/error for `id`.
func isResponse(for id: RequestID) -> @Sendable (Data) -> Bool {
    { data in
        (try? JSONRPCMessage(data: data)).map {
            switch $0 {
            case .response(let response): return response.id == id
            case .error(let errorResponse): return errorResponse.id == id
            default: return false
            }
        } ?? false
    }
}
