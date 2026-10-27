import Foundation
import JSONRPCKit
import Logging

/// An MCP server: wraps a ``ServerDelegate`` and a `JSONRPCPeer`, registering the
/// server-side JSON-RPC methods and dispatching incoming requests/notifications to
/// the delegate.
///
/// Handlers are registered only for the capabilities the delegate advertises, so
/// unadvertised methods are answered with `-32601` (method not found). Requests
/// arriving before `initialize` are answered with `-32002` (server not initialized).
///
/// ```swift
/// let server = Server(delegate: MyServer())  // stdio over this process's stdin/stdout
/// try await server.run()                     // serves until stdin EOF
/// ```
public actor Server {
    /// How long ``run()`` keeps waiting for responses to requests that were received
    /// before the message stream ended. Covers a client that pipelines a batch of
    /// requests and closes stdin immediately: the connection is not declared
    /// terminated until every one of those requests has been answered (or this
    /// timeout elapses, e.g. a handler that never returns).
    private static let drainTimeout: TimeInterval = 30

    private let peer: JSONRPCPeer
    private let transport: DrainingTransport
    private let delegate: any ServerDelegate
    private let logger: Logger

    private var clientInfoValue: Implementation?
    private var clientCapabilitiesValue: ClientCapabilities?
    private var initializeCompleted = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var hasTerminated = false
    private var stateWatcher: Task<Void, Never>?

    public init(
        transport: any Transport,
        delegate: any ServerDelegate,
        logger: Logger = Logger(
            label: "MCPKit.Server", factory: { StreamLogHandler.standardError(label: $0) })
    ) {
        let draining = DrainingTransport(base: transport)
        self.transport = draining
        self.peer = JSONRPCPeer(transport: draining, logger: logger)
        self.delegate = delegate
        self.logger = logger
    }

    /// Creates a server speaking MCP over this process's own stdin/stdout (the standard
    /// transport for an MCP server launched as a subprocess).
    ///
    /// MCPKit's default logger writes to stderr, so diagnostics can never corrupt the
    /// stdout protocol channel; pass an explicit `logger` to route elsewhere.
    public init(
        delegate: any ServerDelegate,
        logger: Logger = Logger(
            label: "MCPKit.Server", factory: { StreamLogHandler.standardError(label: $0) })
    ) {
        self.init(transport: StdioTransport(), delegate: delegate, logger: logger)
    }

    /// The client's implementation info, once `initialize` has been handled.
    public var clientInfo: Implementation? { clientInfoValue }

    /// The capabilities the client advertised, once `initialize` has been handled.
    public var clientCapabilities: ClientCapabilities? { clientCapabilitiesValue }

    /// Whether the `initialize` handshake has been handled.
    public var isInitialized: Bool { initializeCompleted }

    // MARK: - Lifecycle

    /// Registers all handlers and starts the underlying transport/peer.
    ///
    /// Once started, the server retains itself until the transport terminates
    /// (e.g. stdin EOF) or ``close()`` is called, so it keeps serving even if the
    /// caller drops its last reference.
    public func start() async throws {
        await registerHandlers()
        try await peer.start()
        watchForTermination()
    }

    /// Starts the server and suspends until the transport closes (e.g. stdin EOF for a
    /// stdio server) or ``close()`` is called.
    ///
    /// After the message stream ends, the server waits for every request received
    /// before the end to be answered before returning (up to a 30-second drain
    /// timeout), so a client that pipelines requests and closes stdin immediately
    /// does not lose responses.
    ///
    /// Cancellation is treated as shutdown: cancelling the task running `run()`
    /// closes the connection and resumes normally.
    public func run() async throws {
        try await start()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if hasTerminated {
                    continuation.resume()
                } else {
                    stopContinuation = continuation
                }
            }
        } onCancel: {
            // Hop into the actor; finish()/close() are safe to call from here
            // even before the continuation is registered.
            Task { await self.close() }
        }
    }

    /// Closes the underlying peer/transport and resumes a parked ``run()``. Safe to
    /// call multiple times.
    public func close() async {
        finish()
        await peer.close()
    }

    // MARK: - Outgoing notifications

    /// Emits `notifications/tools/list_changed`: the tool list has changed, clients
    /// should re-fetch.
    public func notifyToolsListChanged() async throws {
        try await peer.sendNotification(
            method: "notifications/tools/list_changed", params: EmptyResult())
    }

    /// Emits `notifications/resources/list_changed`: the resource list has changed,
    /// clients should re-fetch.
    public func notifyResourceListChanged() async throws {
        try await peer.sendNotification(
            method: "notifications/resources/list_changed", params: EmptyResult())
    }

    /// Emits `notifications/resources/updated`: the contents of `uri` have changed.
    public func notifyResourceUpdated(uri: String) async throws {
        try await peer.sendNotification(
            method: "notifications/resources/updated",
            params: ResourceUpdatedNotification(uri: uri))
    }

    /// Emits `notifications/prompts/list_changed`: the prompt list has changed, clients
    /// should re-fetch.
    public func notifyPromptsListChanged() async throws {
        try await peer.sendNotification(
            method: "notifications/prompts/list_changed", params: EmptyResult())
    }

    /// Emits `notifications/message`: a structured log entry.
    public func sendLogMessage(
        level: LoggingLevel, logger name: String? = nil, data: JSONValue
    ) async throws {
        try await peer.sendNotification(
            method: "notifications/message",
            params: LogMessageNotification(level: level, logger: name, data: data))
    }

    // MARK: - Outgoing requests (server → client)

    /// Sends `ping` to the client as a liveness check.
    public func ping(timeout: TimeInterval? = nil) async throws {
        try requireInitialized()
        _ = try await peer.sendRequest(
            method: "ping", params: PingRequest(), as: EmptyResult.self, timeout: timeout)
    }

    /// Sends `roots/list`: asks the client for its workspace roots. Requires the
    /// client's `roots` capability.
    public func listRoots(timeout: TimeInterval? = nil) async throws -> ListRootsResult {
        try requireInitialized()
        try requireClientCapability(
            clientCapabilitiesValue?.roots != nil, "client does not advertise 'roots'")
        return try await peer.sendRequest(
            method: "roots/list", params: ListRootsRequest(), as: ListRootsResult.self,
            timeout: timeout)
    }

    /// Sends `sampling/createMessage`: asks the client's LLM to generate a message.
    /// Requires the client's `sampling` capability.
    public func createMessage(
        _ request: CreateMessageRequest, timeout: TimeInterval? = nil
    ) async throws -> CreateMessageResult {
        try requireInitialized()
        try requireClientCapability(
            clientCapabilitiesValue?.sampling != nil,
            "client does not advertise 'sampling'")
        return try await peer.sendRequest(
            method: "sampling/createMessage", params: request, as: CreateMessageResult.self,
            timeout: timeout)
    }

    /// Sends `elicitation/create`: asks the client to gather structured input from the
    /// user. Requires the client's `elicitation` capability.
    public func elicit(
        _ request: ElicitRequest, timeout: TimeInterval? = nil
    ) async throws -> ElicitResult {
        try requireInitialized()
        try requireClientCapability(
            clientCapabilitiesValue?.elicitation != nil,
            "client does not advertise 'elicitation'")
        return try await peer.sendRequest(
            method: "elicitation/create", params: request, as: ElicitResult.self,
            timeout: timeout)
    }

    // MARK: - Handler registration

    private func registerHandlers() async {
        await peer.onRequest(method: "initialize") { [weak self] params in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.handleInitialize(params)
        }
        await peer.onRequest(method: "ping") { [weak self] _ in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.handlePing()
        }
        await peer.onNotification(method: "notifications/initialized") { [weak self] _ in
            await self?.handleClientInitialized()
        }
        await peer.onNotification(method: "notifications/roots/list_changed") { [weak self] _ in
            await self?.handleRootsListChanged()
        }

        let capabilities = delegate.capabilities
        if capabilities.tools != nil {
            await peer.onRequest(method: "tools/list") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleListTools(params)
            }
            await peer.onRequest(method: "tools/call") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleCallTool(params)
            }
        }
        if capabilities.resources != nil {
            await peer.onRequest(method: "resources/list") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleListResources(params)
            }
            await peer.onRequest(method: "resources/templates/list") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleListResourceTemplates(params)
            }
            await peer.onRequest(method: "resources/read") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleReadResource(params)
            }
            if capabilities.resources?.subscribe == true {
                await peer.onRequest(method: "resources/subscribe") { [weak self] params in
                    guard let self else { throw MCPError.connectionClosed }
                    return try await self.handleSubscribe(params)
                }
                await peer.onRequest(method: "resources/unsubscribe") { [weak self] params in
                    guard let self else { throw MCPError.connectionClosed }
                    return try await self.handleUnsubscribe(params)
                }
            }
        }
        if capabilities.prompts != nil {
            await peer.onRequest(method: "prompts/list") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleListPrompts(params)
            }
            await peer.onRequest(method: "prompts/get") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleGetPrompt(params)
            }
        }
        if capabilities.logging != nil {
            await peer.onRequest(method: "logging/setLevel") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleSetLogLevel(params)
            }
        }
        if capabilities.completions != nil {
            await peer.onRequest(method: "completion/complete") { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.handleComplete(params)
            }
        }
    }

    // MARK: - Incoming requests

    private func handleInitialize(_ paramsValue: JSONValue?) async throws -> JSONValue {
        let request = try decode(InitializeRequest.self, from: paramsValue)
        clientInfoValue = request.clientInfo
        clientCapabilitiesValue = request.capabilities
        initializeCompleted = true
        // Echo the requested version when we know it; otherwise respond with the
        // latest version we support and let the client disconnect if it cannot speak it.
        let negotiated =
            knownMCPProtocolVersions.contains(request.protocolVersion)
            ? request.protocolVersion : latestMCPProtocolVersion
        if negotiated != request.protocolVersion {
            logger.warning(
                "Client requested protocol version \(request.protocolVersion); responding with \(negotiated)"
            )
        }
        let result = InitializeResult(
            protocolVersion: negotiated,
            capabilities: delegate.capabilities,
            serverInfo: delegate.info,
            instructions: delegate.instructions
        )
        return try JSONValue(encoding: result)
    }

    private func handlePing() async throws -> JSONValue {
        try requireInitialized()
        return try JSONValue(encoding: EmptyResult())
    }

    private func handleListTools(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(ListToolsRequest.self, from: paramsValue)
        return try JSONValue(encoding: await delegate.listTools(request))
    }

    private func handleCallTool(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(CallToolRequest.self, from: paramsValue)
        let context = ServerContext(peer: peer, progressToken: request.meta?.progressToken)
        return try JSONValue(encoding: await delegate.callTool(request, context: context))
    }

    private func handleListResources(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(ListResourcesRequest.self, from: paramsValue)
        return try JSONValue(encoding: await delegate.listResources(request))
    }

    private func handleListResourceTemplates(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(ListResourceTemplatesRequest.self, from: paramsValue)
        return try JSONValue(encoding: await delegate.listResourceTemplates(request))
    }

    private func handleReadResource(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(ReadResourceRequest.self, from: paramsValue)
        let context = ServerContext(peer: peer, progressToken: request.meta?.progressToken)
        return try JSONValue(encoding: await delegate.readResource(request, context: context))
    }

    private func handleSubscribe(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(SubscribeRequest.self, from: paramsValue)
        try await delegate.subscribe(request)
        return try JSONValue(encoding: EmptyResult())
    }

    private func handleUnsubscribe(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(UnsubscribeRequest.self, from: paramsValue)
        try await delegate.unsubscribe(request)
        return try JSONValue(encoding: EmptyResult())
    }

    private func handleListPrompts(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(ListPromptsRequest.self, from: paramsValue)
        return try JSONValue(encoding: await delegate.listPrompts(request))
    }

    private func handleGetPrompt(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(GetPromptRequest.self, from: paramsValue)
        let context = ServerContext(peer: peer, progressToken: request.meta?.progressToken)
        return try JSONValue(encoding: await delegate.getPrompt(request, context: context))
    }

    private func handleSetLogLevel(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(SetLevelRequest.self, from: paramsValue)
        await delegate.setLogLevel(request)
        return try JSONValue(encoding: EmptyResult())
    }

    private func handleComplete(_ paramsValue: JSONValue?) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(CompleteRequest.self, from: paramsValue)
        return try JSONValue(encoding: await delegate.complete(request))
    }

    // MARK: - Incoming notifications

    private func handleClientInitialized() {
        logger.debug("Client sent notifications/initialized; handshake complete")
    }

    private func handleRootsListChanged() async {
        await delegate.rootsListChanged()
    }

    // MARK: - Termination

    /// Parks a task that completes when the transport has terminated and all requests
    /// received before the end of the message stream have been answered. Keyed off
    /// the draining wrapper rather than the transport's `state` stream because
    /// `StdioTransport.close()` reports only `.closing`, and EOF alone does not imply
    /// that detached response tasks have written yet.
    private func watchForTermination() {
        // Holds `self` strongly for the watcher's lifetime: once `start()` has been
        // called, the server stays alive until the transport terminates (EOF) or
        // ``close()`` is called, even if the caller drops its last reference.
        stateWatcher = Task {
            await self.transport.waitForTermination(drainTimeout: Self.drainTimeout)
            await self.finish()
        }
    }

    private func finish() {
        stateWatcher?.cancel()
        stateWatcher = nil
        guard !hasTerminated else { return }
        hasTerminated = true
        stopContinuation?.resume()
        stopContinuation = nil
    }

    // MARK: - Guards

    private func requireInitialized() throws {
        guard initializeCompleted else { throw MCPError.serverNotInitialized }
    }

    private func requireClientCapability(_ supported: Bool, _ description: String) throws {
        guard supported else { throw MCPError.capabilityNotSupported(description) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from paramsValue: JSONValue?) throws -> T {
        try (paramsValue ?? .object([:])).decode(as: T.self)
    }
}
