import Foundation
import JSONRPCKit
import Synchronization
import Testing

@testable import MCPKit

// MARK: - Tables

struct ClientConnectCase: Sendable {
    var name: String
    var serverVersion: String
    /// Whether `connect()` is expected to throw.
    var expectedFailure: Bool
}

struct ClientCapabilityGateCase: Sendable {
    var name: String
    /// The operation attempted, as a closure over a connected client.
    var operation: @Sendable (Client) async throws -> Void
    var expectedError: MCPError
}

// MARK: - Fixtures

/// Server-side answers the fake transport serves to the client under test.
enum FakeServer {
    /// The standard `initialize` result the fake server answers with.
    static func initializeResult(capabilities: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "protocolVersion": .string(latestMCPProtocolVersion),
            "capabilities": .object(capabilities),
            "serverInfo": .object([
                "name": .string("fake-server"),
                "version": .string("9.9.9"),
            ]),
        ])
    }

    /// Serves a canned answer for a method.
    static func answer(
        for method: String, capabilities: [String: JSONValue] = [:]
    ) throws -> JSONValue {
        switch method {
        case "initialize":
            return initializeResult(capabilities: capabilities)
        case "ping":
            return .object([:])
        case "tools/list":
            return .object([
                "tools": .array([
                    .object(["name": .string("echo"), "description": .string("echoes")])
                ])
            ])
        case "tools/call":
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
                "isError": .bool(false),
            ])
        default:
            return .object([:])
        }
    }
}

/// A client-side delegate recording server-initiated traffic.
final class RecordingClient: ClientDelegate, @unchecked Sendable {
    let capabilities: ClientCapabilities
    private let eventsMutex = Mutex<[String]>([])
    var events: [String] { eventsMutex.withLock { $0 } }

    init(capabilities: ClientCapabilities = ClientCapabilities()) {
        self.capabilities = capabilities
    }

    func ping(_ request: PingRequest) async throws -> EmptyResult { EmptyResult() }

    func listRoots(_ request: ListRootsRequest) async throws -> ListRootsResult {
        eventsMutex.withLock { $0.append("roots/list") }
        return ListRootsResult(roots: [Root(uri: "file:///work", name: "work")])
    }

    func createMessage(_ request: CreateMessageRequest) async throws -> CreateMessageResult {
        eventsMutex.withLock { $0.append("sampling/createMessage") }
        return CreateMessageResult(
            role: .assistant, content: .text("sampled"), model: "fake-model")
    }

    func elicit(_ request: ElicitRequest) async throws -> ElicitResult {
        eventsMutex.withLock { $0.append("elicitation/create") }
        return ElicitResult(action: .accept, content: .text("elicited"))
    }

    func toolsListChanged() async {
        eventsMutex.withLock { $0.append("tools/list_changed") }
    }

    func resourceListChanged() async {
        eventsMutex.withLock { $0.append("resources/list_changed") }
    }

    func resourceUpdated(uri: String) async {
        eventsMutex.withLock { $0.append("resources/updated:\(uri)") }
    }

    func promptsListChanged() async {
        eventsMutex.withLock { $0.append("prompts/list_changed") }
    }

    func logMessage(_ notification: LogMessageNotification) async {
        eventsMutex.withLock { $0.append("message:\(notification.level.rawValue)") }
    }
}

/// Builds a client on an `AutoRespondingTransport` and connects it, returning
/// both. The fake server answers `initialize` with the given capabilities.
@discardableResult
private func connectedClient(
    capabilities: [String: JSONValue] = ["tools": .object([:])],
    delegate: ClientDelegate? = nil,
    configure: ((AutoRespondingTransport) -> Void)? = nil
) async throws -> (client: Client, transport: AutoRespondingTransport) {
    let transport = AutoRespondingTransport()
    configure?(transport)
    let client = Client(transport: transport, delegate: delegate)
    transport.handler = { method, _ in
        try FakeServer.answer(for: method, capabilities: capabilities)
    }
    _ = try await client.connect(timeout: 5)
    return (client, transport)
}

// MARK: - connect

struct ClientConnectTests {
    @Test("connect negotiates protocol version", arguments: [
        ClientConnectCase(name: "same version", serverVersion: latestMCPProtocolVersion, expectedFailure: false),
        ClientConnectCase(name: "older known version", serverVersion: "2025-06-18", expectedFailure: false),
        ClientConnectCase(name: "unknown version", serverVersion: "1999-01-01", expectedFailure: true),
    ])
    func connectNegotiates(testCase: ClientConnectCase) async throws {
        let transport = AutoRespondingTransport()
        transport.handler = { method, _ in
            if method == "initialize" {
                var result = FakeServer.initializeResult().objectValue ?? [:]
                result["protocolVersion"] = .string(testCase.serverVersion)
                return .object(result)
            }
            return try FakeServer.answer(for: method)
        }
        let client = Client(transport: transport)
        do {
            let result = try await client.connect(timeout: 5)
            #expect(!testCase.expectedFailure)
            #expect(result.protocolVersion == testCase.serverVersion)
            #expect(await client.isConnected)
            #expect(await client.serverInfo?.name == "fake-server")
        } catch {
            #expect(testCase.expectedFailure)
            #expect(
                error is MCPError
                    && (error as? MCPError) == .unsupportedProtocolVersion(testCase.serverVersion))
        }
    }

    @Test("connect sends initialize followed by notifications/initialized")
    func handshakeSequence() async throws {
        let (_, transport) = try await connectedClient()

        let methods = transport.sent.compactMap { data -> String? in
            guard let message = try? JSONRPCMessage(data: data) else { return nil }
            switch message {
            case .request(let request): return request.method
            case .notification(let notification): return notification.method
            default: return nil
            }
        }
        #expect(methods.first == "initialize")
        #expect(methods.dropFirst().first == "notifications/initialized")
    }

    @Test("operations before connect throw notConnected")
    func notConnected() async throws {
        let client = Client(transport: AutoRespondingTransport())
        await #expect(throws: MCPError.notConnected) {
            _ = try await client.listTools()
        }
        await #expect(throws: MCPError.notConnected) {
            try await client.ping()
        }
    }

    @Test("empty command is rejected")
    func emptyCommand() {
        #expect(throws: MCPError.self) {
            _ = try Client(command: "")
        }
    }
}

// MARK: - Capability gating

struct ClientCapabilityGateTests {
    @Test("operations are gated on server capabilities", arguments: [
        ClientCapabilityGateCase(
            name: "tools",
            operation: { client in _ = try await client.listTools() },
            expectedError: .capabilityNotSupported("server does not advertise 'tools'")),
        ClientCapabilityGateCase(
            name: "resources",
            operation: { client in _ = try await client.listResources() },
            expectedError: .capabilityNotSupported("server does not advertise 'resources'")),
        ClientCapabilityGateCase(
            name: "resource templates",
            operation: { client in _ = try await client.listResourceTemplates() },
            expectedError: .capabilityNotSupported("server does not advertise 'resources'")),
        ClientCapabilityGateCase(
            name: "prompts",
            operation: { client in _ = try await client.listPrompts() },
            expectedError: .capabilityNotSupported("server does not advertise 'prompts'")),
        ClientCapabilityGateCase(
            name: "logging",
            operation: { client in try await client.setLogLevel(.debug) },
            expectedError: .capabilityNotSupported("server does not advertise 'logging'")),
        ClientCapabilityGateCase(
            name: "completions",
            operation: {
                client in
                _ = try await client.complete(ref: .prompt("p"), argumentName: "a", value: "v")
            },
            expectedError: .capabilityNotSupported("server does not advertise 'completions'")),
        ClientCapabilityGateCase(
            name: "resources.subscribe",
            operation: { client in try await client.subscribe(uri: "test://res") },
            expectedError: .capabilityNotSupported("server does not advertise 'resources.subscribe'")),
    ])
    func gating(testCase: ClientCapabilityGateCase) async throws {
        // Server advertises nothing.
        let (client, _) = try await connectedClient(capabilities: [:])
        do {
            try await testCase.operation(client)
            Issue.record("expected \(testCase.expectedError) for \(testCase.name)")
        } catch let error as MCPError {
            #expect(error == testCase.expectedError)
        }
    }
}

// MARK: - Tools

struct ClientToolsTests {
    @Test("listTools follows pagination cursors to exhaustion")
    func pagination() async throws {
        let (client, transport) = try await connectedClient()
        let page = Mutex(0)
        transport.handler = { method, params in
            guard method == "tools/list" else { return try FakeServer.answer(for: method) }
            let pageNumber = page.withLock {
                $0 += 1
                return $0
            }
            if pageNumber == 1 {
                return .object([
                    "tools": .array([
                        .object(["name": .string("echo"), "description": .string("echoes")])
                    ]),
                    "nextCursor": .string("page-2"),
                ])
            }
            return .object([
                "tools": .array([
                    .object(["name": .string("add"), "description": .string("adds")])
                ])
            ])
        }

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo", "add"])
        #expect(page.withLock { $0 } == 2)
    }

    @Test("callTool returns results and passes arguments")
    func callTool() async throws {
        let (client, transport) = try await connectedClient()
        transport.handler = { method, params in
            if method == "tools/call" {
                return .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("hi")])]),
                    "isError": .bool(false),
                ])
            }
            return try FakeServer.answer(for: method)
        }

        let result = try await client.callTool(name: "echo", arguments: ["text": .string("hi")])
        #expect(result.content == [.text("hi")])
        #expect(result.combinedText == "hi")

        // The request carried the arguments.
        let call = transport.sent.compactMap { data -> JSONRPCRequest? in
            guard case .request(let request) = try? JSONRPCMessage(data: data),
                request.method == "tools/call"
            else { return nil }
            return request
        }.last
        #expect(call?.params?.objectValue?["name"]?.stringValue == "echo")
        #expect(
            call?.params?.objectValue?["arguments"]?.objectValue?["text"]?.stringValue == "hi")
    }

    @Test("callTool surfaces isError results without throwing")
    func callToolErrorResult() async throws {
        let (client, transport) = try await connectedClient()
        transport.handler = { method, _ in
            if method == "tools/call" {
                return .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("boom")])]),
                    "isError": .bool(true),
                ])
            }
            return try FakeServer.answer(for: method)
        }

        let result = try await client.callTool(name: "explode")
        #expect(result.isError)
        #expect(result.combinedText == "boom")
    }

    @Test("callTool attaches a progress token only when onProgress is set")
    func progressTokenAttachment() async throws {
        let (client, transport) = try await connectedClient()
        _ = try await client.callTool(name: "echo")

        let withoutHandler = transport.sent.compactMap { data -> JSONRPCRequest? in
            guard case .request(let request) = try? JSONRPCMessage(data: data),
                request.method == "tools/call"
            else { return nil }
            return request
        }.last
        #expect(
            withoutHandler?.params?.objectValue?["_meta"] == nil,
            "no _meta should be attached without a progress handler")

        _ = try await client.callTool(name: "echo", onProgress: { _ in })
        let withHandler = transport.sent.compactMap { data -> JSONRPCRequest? in
            guard case .request(let request) = try? JSONRPCMessage(data: data),
                request.method == "tools/call"
            else { return nil }
            return request
        }.last
        #expect(withHandler?.params?.objectValue?["_meta"]?.objectValue?["progressToken"] != nil)
    }

    @Test("progress notifications route to the matching call's onProgress")
    func progressRouting() async throws {
        let (client, transport) = try await connectedClient()
        let received = Mutex<[ProgressNotification]>([])

        // The fake server emits a progress notification for the in-flight
        // tools/call before answering it.
        transport.sideEffect = { [weak transport] in
            guard let transport else { return }
            let notification = try? rpcNotificationData(
                method: "notifications/progress",
                params: .object([
                    "progressToken": .number(0),
                    "progress": .number(0.25),
                    "total": .number(1),
                ]))
            if let notification {
                transport.inject(notification)
            }
        }

        let result = try await client.callTool(name: "echo") { notification in
            received.withLock { $0.append(notification) }
        }
        #expect(!result.isError)
        let updates = received.withLock { $0 }
        #expect(updates.count == 1)
        #expect(updates.first?.progressToken == .number(0))
        #expect(updates.first?.progress == 0.25)
        #expect(updates.first?.total == 1)
    }
}

// MARK: - Server-initiated traffic

struct ClientServerInitiatedTests {
    @Test("server requests dispatch to the delegate")
    func dispatch() async throws {
        let delegate = RecordingClient(
            capabilities: ClientCapabilities(
                roots: RootsCapability(), sampling: SamplingCapability(),
                elicitation: ElicitationCapability()))
        let (client, transport) = try await connectedClient(delegate: delegate)

        transport.inject(
            try rpcRequestData(
                id: .number(50), method: "roots/list", params: .object([:])))
        let rootsResponse = try await transport.awaitSent(matching: isResponse(for: .number(50)))
        guard case .response(let rootsPayload) = try JSONRPCMessage(data: rootsResponse) else {
            Issue.record("expected roots/list success response")
            return
        }
        let roots = try rootsPayload.result.decode(as: ListRootsResult.self)
        #expect(roots.roots.map(\.uri) == ["file:///work"])

        transport.inject(
            try rpcRequestData(
                id: .number(51), method: "sampling/createMessage",
                params: try jsonObject(
                    #"""
                    {"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 10}
                    """#)))
        let samplingResponse = try await transport.awaitSent(matching: isResponse(for: .number(51)))
        guard case .response(let samplingPayload) = try JSONRPCMessage(data: samplingResponse)
        else {
            Issue.record("expected sampling success response")
            return
        }
        let sampled = try samplingPayload.result.decode(as: CreateMessageResult.self)
        #expect(sampled.model == "fake-model")

        transport.inject(
            try rpcRequestData(
                id: .number(52), method: "elicitation/create",
                params: try jsonObject(
                    #"""
                    {"message": "pick", "requestedSchema": {"type": "object"}}
                    """#)))
        let elicitResponse = try await transport.awaitSent(matching: isResponse(for: .number(52)))
        guard case .response(let elicitPayload) = try JSONRPCMessage(data: elicitResponse) else {
            Issue.record("expected elicitation success response")
            return
        }
        let elicited = try elicitPayload.result.decode(as: ElicitResult.self)
        #expect(elicited.action == .accept)

        #expect(delegate.events.contains("roots/list"))
        #expect(delegate.events.contains("sampling/createMessage"))
        #expect(delegate.events.contains("elicitation/create"))
        _ = client
    }

    @Test("ping from the server is answered")
    func serverPing() async throws {
        let (client, transport) = try await connectedClient()
        transport.inject(try rpcRequestData(id: .number(60), method: "ping", params: .object([:])))

        let response = try await transport.awaitSent(matching: isResponse(for: .number(60)))
        guard case .response(let payload) = try JSONRPCMessage(data: response) else {
            Issue.record("expected ping success response")
            return
        }
        #expect(payload.result == .object([:]))
        _ = client
    }

    @Test("notifications dispatch to the delegate", arguments: [
        ("notifications/tools/list_changed", "tools/list_changed"),
        ("notifications/resources/list_changed", "resources/list_changed"),
        ("notifications/prompts/list_changed", "prompts/list_changed"),
    ])
    func notificationDispatch(method: String, expectedEvent: String) async throws {
        let delegate = RecordingClient()
        let (client, transport) = try await connectedClient(delegate: delegate)

        transport.inject(try rpcNotificationData(method: method, params: .object([:])))
        try await waitFor { delegate.events.contains(expectedEvent) }
        #expect(delegate.events == [expectedEvent])
        _ = client
    }

    @Test("resources/updated carries the uri")
    func resourceUpdated() async throws {
        let delegate = RecordingClient()
        let (client, transport) = try await connectedClient(delegate: delegate)

        transport.inject(
            try rpcNotificationData(
                method: "notifications/resources/updated",
                params: .object(["uri": .string("test://res")])))
        try await waitFor { !delegate.events.isEmpty }
        #expect(delegate.events == ["resources/updated:test://res"])
        _ = client
    }

    @Test("log messages dispatch to the delegate")
    func logMessage() async throws {
        let delegate = RecordingClient()
        let (client, transport) = try await connectedClient(delegate: delegate)

        transport.inject(
            try rpcNotificationData(
                method: "notifications/message",
                params: .object(["level": .string("warning"), "data": .string("careful")])))
        try await waitFor { !delegate.events.isEmpty }
        #expect(delegate.events == ["message:warning"])
        _ = client
    }
}
