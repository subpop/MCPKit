import Foundation
import JSONRPCKit
import Synchronization
import Testing

@testable import MCPKit

// MARK: - Tables

struct ServerInitializeCase: Sendable {
    var name: String
    var requestedVersion: String
    var expectedVersion: String
}

struct ServerErrorCase: Sendable {
    var name: String
    /// Raw JSON-RPC request injected before initialize.
    var method: String
    var params: String
    var expectedCode: Int
}

// MARK: - Fixtures

/// A configurable server-side delegate that records the requests it serves.
/// Handlers run on detached tasks, so state is guarded by a mutex.
final class RecordingServer: ServerDelegate, @unchecked Sendable {
    let capabilities: ServerCapabilities
    let info: Implementation
    let instructions: String?

    struct Toolkit: Sendable {
        var tools: [Tool] = [
            Tool(name: "echo", description: "echoes text", inputSchema: [:])
        ]
        var echoText: @Sendable (String) -> String = { $0 }
        var reportProgress: Bool = false
    }

    let toolkit: Toolkit
    private let callsMutex = Mutex<[String]>([])
    var calls: [String] { callsMutex.withLock { $0 } }

    init(
        capabilities: ServerCapabilities = ServerCapabilities(tools: ToolsCapability()),
        info: Implementation = Implementation(name: "recording-server", version: "1.0.0"),
        instructions: String? = nil,
        toolkit: Toolkit = Toolkit()
    ) {
        self.capabilities = capabilities
        self.info = info
        self.instructions = instructions
        self.toolkit = toolkit
    }

    func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult {
        callsMutex.withLock { $0.append("tools/list") }
        return ListToolsResult(tools: toolkit.tools)
    }

    func callTool(_ request: CallToolRequest, context: ServerContext) async throws
        -> CallToolResult
    {
        callsMutex.withLock { $0.append("tools/call:\(request.name)") }
        if toolkit.reportProgress {
            try await context.reportProgress(0.5, total: 1.0, message: "halfway")
        }
        let text = request.arguments?["text"]?.stringValue ?? ""
        return CallToolResult(content: [.text(toolkit.echoText(text))])
    }

    func listResources(_ request: ListResourcesRequest) async throws -> ListResourcesResult {
        callsMutex.withLock { $0.append("resources/list") }
        return ListResourcesResult(
            resources: [Resource(uri: "test://res", name: "res", mimeType: "text/plain")])
    }

    func readResource(
        _ request: ReadResourceRequest, context: ServerContext
    ) async throws -> ReadResourceResult {
        callsMutex.withLock { $0.append("resources/read:\(request.uri)") }
        return ReadResourceResult(
            contents: [ResourceContents(uri: request.uri, mimeType: "text/plain", text: "body")])
    }

    func listPrompts(_ request: ListPromptsRequest) async throws -> ListPromptsResult {
        callsMutex.withLock { $0.append("prompts/list") }
        return ListPromptsResult(
            prompts: [Prompt(name: "greet", description: "greets")])
    }

    func getPrompt(
        _ request: GetPromptRequest, context: ServerContext
    ) async throws -> GetPromptResult {
        callsMutex.withLock { $0.append("prompts/get:\(request.name)") }
        return GetPromptResult(
            description: "rendered",
            messages: [PromptMessage(role: .user, content: .text("hello"))])
    }

    func complete(_ request: CompleteRequest) async throws -> CompleteResult {
        callsMutex.withLock { $0.append("completion/complete") }
        return CompleteResult(values: ["alpha", "alphabet"], total: 2)
    }

    func setLogLevel(_ request: SetLevelRequest) async {
        callsMutex.withLock { $0.append("logging/setLevel:\(request.level.rawValue)") }
    }

    func rootsListChanged() async {
        callsMutex.withLock { $0.append("roots/list_changed") }
    }
}

@discardableResult
private func startedServer(
    transport: CapturingTransport,
    delegate: ServerDelegate = RecordingServer()
) async throws -> Server {
    let server = Server(transport: transport, delegate: delegate)
    try await server.start()
    return server
}/// Injects the standard handshake: `initialize` + `notifications/initialized`.
private func performHandshake(
    _ transport: CapturingTransport, id: RequestID = .number(0)
) throws {
    transport.inject(
        try rpcRequestData(
            id: id, method: "initialize",
            params: try jsonObject(
                #"""
                {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test-client", "version": "0"}}
                """#)))
    transport.inject(try rpcNotificationData(method: "notifications/initialized"))
}

// MARK: - initialize

struct ServerInitializeTests {
    @Test("negotiates protocol version", arguments: [
        ServerInitializeCase(
            name: "echoes requested version when known",
            requestedVersion: "2025-06-18", expectedVersion: "2025-06-18"),
        ServerInitializeCase(
            name: "responds with latest for unknown version",
            requestedVersion: "1999-01-01", expectedVersion: latestMCPProtocolVersion),
        ServerInitializeCase(
            name: "echoes latest version",
            requestedVersion: latestMCPProtocolVersion, expectedVersion: latestMCPProtocolVersion),
    ])
    func negotiation(testCase: ServerInitializeCase) async throws {
        let transport = CapturingTransport()
        let server = try await startedServer(transport: transport)
        transport.inject(
            try rpcRequestData(
                id: .number(1), method: "initialize",
                params: try jsonObject(
                    #"""
                    {"protocolVersion": "\#(testCase.requestedVersion)", "capabilities": {}, "clientInfo": {"name": "c", "version": "0"}}
                    """#)))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(1)))
        let message = try JSONRPCMessage(data: response)
        guard case .response(let payload) = message else {
            Issue.record("expected success response, got \(message)")
            return
        }
        let result = try payload.result.decode(as: InitializeResult.self)
        #expect(result.protocolVersion == testCase.expectedVersion)
        #expect(result.serverInfo.name == "recording-server")
        #expect(await server.isInitialized)
        #expect(await server.clientInfo?.name == "c")
    }

    @Test("initialize response advertises delegate capabilities and instructions")
    func capabilitiesEchoed() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer(
            capabilities: ServerCapabilities(
                logging: LoggingCapability(),
                prompts: PromptsCapability(listChanged: true),
                tools: ToolsCapability(listChanged: true)),
            instructions: "use responsibly")
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport, id: .number(9))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(9)))
        guard case .response(let payload) = try JSONRPCMessage(data: response) else {
            Issue.record("expected success response")
            return
        }
        let result = try payload.result.decode(as: InitializeResult.self)
        #expect(result.instructions == "use responsibly")
        #expect(result.capabilities.tools?.listChanged == true)
        #expect(result.capabilities.prompts?.listChanged == true)
        #expect(result.capabilities.logging != nil)
    }
}

// MARK: - Guards

struct ServerGuardTests {
    @Test("requests before initialize are rejected with -32002", arguments: [
        ServerErrorCase(name: "tools/list", method: "tools/list", params: "{}", expectedCode: -32002),
        ServerErrorCase(name: "tools/call", method: "tools/call", params: #"{"name": "echo"}"#, expectedCode: -32002),
        ServerErrorCase(name: "ping", method: "ping", params: "{}", expectedCode: -32002),
    ])
    func preInitialize(testCase: ServerErrorCase) async throws {
        let transport = CapturingTransport()
        _ = try await startedServer(transport: transport)
        transport.inject(
            try rpcRequestData(
                id: .number(1), method: testCase.method,
                params: try jsonObject(testCase.params)))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(1)))
        guard case .error(let error) = try JSONRPCMessage(data: response) else {
            Issue.record("expected error response for pre-initialize \(testCase.method)")
            return
        }
        #expect(error.error.code == testCase.expectedCode)
    }

    @Test("unadvertised methods are rejected with -32601", arguments: [
        "prompts/list", "resources/list", "completion/complete", "logging/setLevel",
        "no/such-method",
    ])
    func unadvertised(method: String) async throws {
        let transport = CapturingTransport()
        // Delegate advertises only tools.
        _ = try await startedServer(transport: transport)
        try performHandshake(transport)
        transport.inject(try rpcRequestData(id: .number(2), method: method, params: .object([:])))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(2)))
        guard case .error(let error) = try JSONRPCMessage(data: response) else {
            Issue.record("expected -32601 for unadvertised \(method)")
            return
        }
        #expect(error.error.code == -32601)
    }
}

// MARK: - Dispatch

struct ServerDispatchTests {
    @Test("ping answers an empty result")
    func ping() async throws {
        let transport = CapturingTransport()
        _ = try await startedServer(transport: transport)
        try performHandshake(transport)
        transport.inject(try rpcRequestData(id: .number(5), method: "ping", params: .object([:])))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(5)))
        guard case .response(let payload) = try JSONRPCMessage(data: response) else {
            Issue.record("expected ping success response")
            return
        }
        #expect(payload.result == .object([:]))
    }

    @Test("tools/list and tools/call dispatch to the delegate")
    func toolsDispatch() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer()
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport)

        transport.inject(try rpcRequestData(id: .number(1), method: "tools/list", params: .object([:])))
        let listResponse = try await transport.awaitSent(matching: isResponse(for: .number(1)))
        guard case .response(let listPayload) = try JSONRPCMessage(data: listResponse) else {
            Issue.record("expected tools/list response")
            return
        }
        let listResult = try listPayload.result.decode(as: ListToolsResult.self)
        #expect(listResult.tools.map(\.name) == ["echo"])

        transport.inject(
            try rpcRequestData(
                id: .number(2), method: "tools/call",
                params: try jsonObject(#"{"name": "echo", "arguments": {"text": "hi there"}}"#)))
        let callResponse = try await transport.awaitSent(matching: isResponse(for: .number(2)))
        guard case .response(let callPayload) = try JSONRPCMessage(data: callResponse) else {
            Issue.record("expected tools/call response")
            return
        }
        let callResult = try callPayload.result.decode(as: CallToolResult.self)
        #expect(callResult.content == [.text("hi there")])
        #expect(!callResult.isError)

        #expect(delegate.calls == ["tools/list", "tools/call:echo"])
    }

    @Test("handler errors map to JSON-RPC error codes")
    func handlerErrors() async throws {
        let transport = CapturingTransport()
        struct FailingServer: ServerDelegate {
            let capabilities = ServerCapabilities(tools: ToolsCapability())
            let info = Implementation(name: "failing", version: "1.0.0")
            func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult {
                throw MCPError.invalidParams("cannot list right now")
            }
        }
        _ = try await startedServer(transport: transport, delegate: FailingServer())
        try performHandshake(transport)

        transport.inject(try rpcRequestData(id: .number(3), method: "tools/list", params: .object([:])))
        let response = try await transport.awaitSent(matching: isResponse(for: .number(3)))
        guard case .error(let error) = try JSONRPCMessage(data: response) else {
            Issue.record("expected error response")
            return
        }
        // MCPError conforms to JSONRPCErrorConvertible: invalidParams → -32602.
        #expect(error.error.code == -32602)
        #expect(error.error.message.contains("cannot list right now"))
    }

    @Test("resources/prompts/completions dispatch to the delegate")
    func fullSurfaceDispatch() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer(
            capabilities: ServerCapabilities(
                completions: CompletionsCapability(),
                logging: LoggingCapability(),
                prompts: PromptsCapability(),
                resources: ResourcesCapability(),
                tools: ToolsCapability()))
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport)

        let cases: [(String, String)] = [
            ("resources/list", "{}"),
            ("resources/read", #"{"uri": "test://res"}"#),
            ("prompts/list", "{}"),
            ("prompts/get", #"{"name": "greet"}"#),
            ("completion/complete", #"{"ref": {"type": "ref/prompt", "name": "greet"}, "argument": {"name": "x", "value": "a"}}"#),
            ("logging/setLevel", #"{"level": "debug"}"#),
        ]
        for (index, pair) in cases.enumerated() {
            transport.inject(
                try rpcRequestData(
                    id: .number(100 + index), method: pair.0, params: try jsonObject(pair.1)))
        }

        for index in cases.indices {
            let id = RequestID.number(100 + index)
            let response = try await transport.awaitSent(matching: isResponse(for: id))
            guard case .response = try JSONRPCMessage(data: response) else {
                Issue.record("expected success response for \(cases[index].0)")
                continue
            }
        }

        #expect(delegate.calls.contains("resources/list"))
        #expect(delegate.calls.contains("resources/read:test://res"))
        #expect(delegate.calls.contains("prompts/list"))
        #expect(delegate.calls.contains("prompts/get:greet"))
        #expect(delegate.calls.contains("completion/complete"))
        #expect(delegate.calls.contains("logging/setLevel:debug"))
    }

    @Test("notifications/roots/list_changed reaches the delegate")
    func rootsListChanged() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer()
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport)
        transport.inject(
            try rpcNotificationData(method: "notifications/roots/list_changed"))

        try await waitFor { !delegate.calls.isEmpty }
        #expect(delegate.calls == ["roots/list_changed"])
    }
}

// MARK: - Progress

struct ServerProgressTests {
    @Test("reportProgress emits notifications/progress with the caller's token")
    func progress() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer(
            toolkit: RecordingServer.Toolkit(reportProgress: true))
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport)

        transport.inject(
            try rpcRequestData(
                id: .number(7), method: "tools/call",
                params: try jsonObject(
                    #"""
                    {"name": "echo", "arguments": {"text": "slow"}, "_meta": {"progressToken": "p1"}}
                    """#)))

        // First the progress notification, then the response.
        let notification = try await transport.awaitSent(
            matching: { data in
                guard let message = try? JSONRPCMessage(data: data),
                    case .notification(let note) = message,
                    note.method == "notifications/progress"
                else { return false }
                let progress = try? note.params?.decode(as: ProgressNotification.self)
                return progress?.progressToken == .string("p1")
                    && progress?.progress == 0.5
            })
        #expect(notification.count > 0)

        let response = try await transport.awaitSent(matching: isResponse(for: .number(7)))
        guard case .response = try JSONRPCMessage(data: response) else {
            Issue.record("expected tools/call response after progress")
            return
        }
    }

    @Test("reportProgress is a no-op without a caller token")
    func progressWithoutToken() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer(
            toolkit: RecordingServer.Toolkit(reportProgress: true))
        _ = try await startedServer(transport: transport, delegate: delegate)
        try performHandshake(transport)

        transport.inject(
            try rpcRequestData(
                id: .number(8), method: "tools/call",
                params: try jsonObject(#"{"name": "echo", "arguments": {"text": "x"}}"#)))

        _ = try await transport.awaitSent(matching: isResponse(for: .number(8)))
        // The only traffic should be the response: no progress notification was sent.
        #expect(!transport.sentMessages.contains { message in
            if case .notification(let note) = message {
                return note.method == "notifications/progress"
            }
            return false
        })
    }
}

// MARK: - Termination & drain

struct ServerTerminationTests {
    @Test("run() drains pending responses when the message stream ends immediately")
    func drainsPendingResponses() async throws {
        let transport = CapturingTransport()
        let delegate = RecordingServer(
            toolkit: RecordingServer.Toolkit(reportProgress: true))

        let server = Server(transport: transport, delegate: delegate)

        // Pipeline a batch of requests and end the stream BEFORE starting the
        // server: AsyncStream buffers the yields, so the peer receives the whole
        // batch followed by immediate EOF — no chance to answer before the
        // stream ends.
        transport.inject(
            try rpcRequestData(
                id: .number(1), method: "initialize",
                params: try jsonObject(
                    #"""
                    {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "c", "version": "0"}}
                    """#)))
        transport.inject(try rpcNotificationData(method: "notifications/initialized"))
        transport.inject(try rpcRequestData(id: .number(2), method: "tools/list", params: .object([:])))
        transport.inject(
            try rpcRequestData(
                id: .number(3), method: "tools/call",
                params: try jsonObject(
                    #"""
                    {"name": "echo", "arguments": {"text": "drain"}, "_meta": {"progressToken": 41}}
                    """#)))
        transport.finish()

        // run() must not return until every pipelined request was answered.
        try await withTimeout(seconds: 10) {
            try await server.run()
        }

        let responseIds = transport.sentMessages.compactMap { message -> Int? in
            switch message {
            case .response(let response):
                if case .number(let n) = response.id { return n }
            case .error(let error):
                if case .number(let n)? = error.id { return n }
            default:
                break
            }
            return nil
        }
        #expect(Set(responseIds) == [1, 2, 3])

        let progressSent = transport.sentMessages.contains { message in
            if case .notification(let note) = message, note.method == "notifications/progress" {
                let progress = try? note.params?.decode(as: ProgressNotification.self)
                return progress?.progressToken == .number(41)
            }
            return false
        }
        #expect(progressSent)
    }

    @Test("close() resumes a parked run()")
    func closeResumesRun() async throws {
        let transport = CapturingTransport()
        let server = Server(transport: transport, delegate: RecordingServer())
        try await withTimeout(seconds: 5) {
            // Close from a concurrent task once run() has had time to park.
            async let closed: Void = {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await server.close()
            }()
            try await server.run()
            await closed
        }
    }

    @Test("cancelling a parked run() shuts the server down instead of hanging")
    func cancellationResumesRun() async throws {
        let transport = CapturingTransport()
        let server = Server(transport: transport, delegate: RecordingServer())
        let runTask = Task { try await server.run() }
        // Give run() a moment to park, then cancel: run() must return promptly.
        try await Task.sleep(nanoseconds: 200_000_000)
        runTask.cancel()
        try await withTimeout(seconds: 5) {
            _ = try await runTask.value
        }
    }
}

// MARK: - Helpers

/// Polls `condition` until it holds, failing after `seconds`.
func waitFor(
    seconds: Double = 2, _ condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Races `body` against a deadline; fails the test if the deadline wins.
func withTimeout<T: Sendable>(
    seconds: Double, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TableTestError.timedOut
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
