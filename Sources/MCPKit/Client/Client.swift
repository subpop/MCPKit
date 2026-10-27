import Foundation
import JSONRPCKit
import Logging

/// An MCP client: connects to a single MCP server over a `Transport` and speaks the
/// MCP JSON-RPC surface (`initialize`, `ping`, `tools/*`, `resources/*`, `prompts/*`,
/// `logging/setLevel`, `completion/complete`), plus the server-initiated surface
/// (`roots/list`, `sampling/createMessage`, `elicitation/create`) via an optional
/// ``ClientDelegate``.
///
/// Transport framing is supplied by the caller. For a stdio server use
/// ``init(command:args:environment:currentDirectory:clientInfo:delegate:logger:)``,
/// which spawns the server as a child process.
///
/// ```swift
/// let client = try Client(command: "npx", args: ["-y", "some-server"])
/// try await client.connect()
/// let tools = try await client.listTools()
/// ```
public actor Client {
    private let peer: JSONRPCPeer
    private let logger: Logger
    private let clientInfo: Implementation
    private let delegate: (any ClientDelegate)?

    private var serverInfoValue: Implementation?
    private var serverCapabilitiesValue: ServerCapabilities?
    private var connected = false

    private var progressHandlers:
        [ProgressToken: @Sendable (ProgressNotification) async -> Void] = [:]
    private var nextProgressTokenNumber = 0

    public init(
        transport: any Transport,
        clientInfo: Implementation = Implementation(name: "MCPKit", version: "1.0.0"),
        delegate: (any ClientDelegate)? = nil,
        logger: Logger = Logger(
            label: "MCPKit.Client", factory: { StreamLogHandler.standardError(label: $0) })
    ) {
        self.peer = JSONRPCPeer(transport: transport, logger: logger)
        self.logger = logger
        self.clientInfo = clientInfo
        self.delegate = delegate
    }

    /// Creates a client that spawns `command` as an MCP stdio server and speaks
    /// newline-delimited JSON-RPC over its pipes.
    ///
    /// MCPKit's default logger writes to stderr, so diagnostics can never corrupt a
    /// stdout protocol channel (relevant when this client runs inside an MCP server
    /// of your own); pass an explicit `logger` to route elsewhere.
    public init(
        command: String,
        args: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        clientInfo: Implementation = Implementation(name: "MCPKit", version: "1.0.0"),
        delegate: (any ClientDelegate)? = nil,
        logger: Logger = Logger(
            label: "MCPKit.Client", factory: { StreamLogHandler.standardError(label: $0) })
    ) throws {
        guard !command.isEmpty else {
            throw MCPError.invalidConfiguration("stdio server command must not be empty")
        }
        let transport = ProcessTransport(
            command: command, args: args, environment: environment,
            currentDirectory: currentDirectory, logger: logger)
        self.init(transport: transport, clientInfo: clientInfo, delegate: delegate, logger: logger)
    }

    /// The server's implementation info, once connected.
    public var serverInfo: Implementation? { serverInfoValue }

    /// The capabilities the server advertised, once connected.
    public var serverCapabilities: ServerCapabilities? { serverCapabilitiesValue }

    /// Whether the `initialize` handshake has completed.
    public var isConnected: Bool { connected }

    // MARK: - Lifecycle

    /// Starts the transport and performs the MCP `initialize` handshake, followed by
    /// the mandatory `notifications/initialized` notification.
    ///
    /// - Parameter timeout: maximum time to wait for the handshake response. Defaults
    ///   to 60 seconds (covers process spawn plus the round-trip), so a server that
    ///   spawns yet never answers throws `JSONRPCPeerError.timedOut` instead of hanging
    ///   forever.
    @discardableResult
    public func connect(timeout: TimeInterval = 60) async throws -> InitializeResult {
        await registerHandlers()
        try await peer.start()

        let request = InitializeRequest(
            protocolVersion: latestMCPProtocolVersion,
            capabilities: delegate?.capabilities ?? ClientCapabilities(),
            clientInfo: clientInfo)
        let result = try await peer.sendRequest(
            method: "initialize", params: request, as: InitializeResult.self, timeout: timeout)
        if result.protocolVersion != latestMCPProtocolVersion {
            guard knownMCPProtocolVersions.contains(result.protocolVersion) else {
                throw MCPError.unsupportedProtocolVersion(result.protocolVersion)
            }
            logger.warning(
                "MCP server negotiated protocol version \(result.protocolVersion) (client proposed \(latestMCPProtocolVersion))"
            )
        }
        try await peer.sendNotification(
            method: "notifications/initialized", params: EmptyResult())
        serverInfoValue = result.serverInfo
        serverCapabilitiesValue = result.capabilities
        connected = true
        logger.info(
            "Connected to MCP server \(result.serverInfo.name) \(result.serverInfo.version)")
        return result
    }

    /// Closes the underlying peer/transport. Safe to call multiple times.
    public func close() async {
        connected = false
        progressHandlers.removeAll()
        await peer.close()
    }

    // MARK: - ping

    /// Pings the server as a liveness check.
    public func ping(timeout: TimeInterval? = nil) async throws {
        try requireConnected()
        _ = try await peer.sendRequest(
            method: "ping", params: PingRequest(), as: EmptyResult.self, timeout: timeout)
    }

    // MARK: - tools

    /// Lists all tools, following `nextCursor` pagination until exhausted.
    ///
    /// - Parameter timeout: maximum time to wait per `tools/list` page. `nil` waits
    ///   indefinitely.
    public func listTools(timeout: TimeInterval? = nil) async throws -> [Tool] {
        var tools: [Tool] = []
        var cursor: String?
        repeat {
            let result = try await listToolsPage(cursor: cursor, timeout: timeout)
            tools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil
        return tools
    }

    /// Fetches a single `tools/list` page.
    public func listToolsPage(
        cursor: String? = nil, timeout: TimeInterval? = nil
    ) async throws -> ListToolsResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.tools != nil, "server does not advertise 'tools'")
        return try await peer.sendRequest(
            method: "tools/list", params: ListToolsRequest(cursor: cursor),
            as: ListToolsResult.self, timeout: timeout)
    }

    /// Calls a tool by name.
    ///
    /// - Parameters:
    ///   - name: The tool name from `tools/list`.
    ///   - arguments: Tool arguments as JSON values.
    ///   - timeout: maximum time to wait for the response. `nil` waits indefinitely.
    ///   - onProgress: invoked for each `notifications/progress` update the server
    ///     sends for this call; a progress token is attached only when non-`nil`.
    public func callTool(
        name: String,
        arguments: [String: JSONValue]? = nil,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (ProgressNotification) async -> Void)? = nil
    ) async throws -> CallToolResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.tools != nil, "server does not advertise 'tools'")
        let token = registerProgressHandler(onProgress)
        defer { unregisterProgressHandler(token) }
        let request = CallToolRequest(
            name: name, arguments: arguments,
            meta: token.map { RequestMeta(progressToken: $0) })
        return try await peer.sendRequest(
            method: "tools/call", params: request, as: CallToolResult.self, timeout: timeout)
    }

    // MARK: - resources

    /// Lists all resources, following `nextCursor` pagination until exhausted.
    public func listResources(timeout: TimeInterval? = nil) async throws -> [Resource] {
        var resources: [Resource] = []
        var cursor: String?
        repeat {
            let result = try await listResourcesPage(cursor: cursor, timeout: timeout)
            resources.append(contentsOf: result.resources)
            cursor = result.nextCursor
        } while cursor != nil
        return resources
    }

    /// Fetches a single `resources/list` page.
    public func listResourcesPage(
        cursor: String? = nil, timeout: TimeInterval? = nil
    ) async throws -> ListResourcesResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.resources != nil, "server does not advertise 'resources'")
        return try await peer.sendRequest(
            method: "resources/list", params: ListResourcesRequest(cursor: cursor),
            as: ListResourcesResult.self, timeout: timeout)
    }

    /// Lists all resource templates, following `nextCursor` pagination until exhausted.
    public func listResourceTemplates(timeout: TimeInterval? = nil) async throws
        -> [ResourceTemplate]
    {
        var templates: [ResourceTemplate] = []
        var cursor: String?
        repeat {
            let result = try await listResourceTemplatesPage(cursor: cursor, timeout: timeout)
            templates.append(contentsOf: result.resourceTemplates)
            cursor = result.nextCursor
        } while cursor != nil
        return templates
    }

    /// Fetches a single `resources/templates/list` page.
    public func listResourceTemplatesPage(
        cursor: String? = nil, timeout: TimeInterval? = nil
    ) async throws -> ListResourceTemplatesResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.resources != nil, "server does not advertise 'resources'")
        return try await peer.sendRequest(
            method: "resources/templates/list",
            params: ListResourceTemplatesRequest(cursor: cursor),
            as: ListResourceTemplatesResult.self, timeout: timeout)
    }

    /// Reads a resource's current contents.
    public func readResource(
        uri: String,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (ProgressNotification) async -> Void)? = nil
    ) async throws -> ReadResourceResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.resources != nil, "server does not advertise 'resources'")
        let token = registerProgressHandler(onProgress)
        defer { unregisterProgressHandler(token) }
        let request = ReadResourceRequest(uri: uri, meta: token.map { RequestMeta(progressToken: $0) })
        return try await peer.sendRequest(
            method: "resources/read", params: request, as: ReadResourceResult.self,
            timeout: timeout)
    }

    /// Subscribes to changes for a resource. Requires the server's
    /// `resources.subscribe` capability.
    public func subscribe(uri: String, timeout: TimeInterval? = nil) async throws {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.resources?.subscribe == true,
            "server does not advertise 'resources.subscribe'")
        _ = try await peer.sendRequest(
            method: "resources/subscribe", params: SubscribeRequest(uri: uri),
            as: EmptyResult.self, timeout: timeout)
    }

    /// Cancels a subscription previously established with ``subscribe(uri:timeout:)``.
    public func unsubscribe(uri: String, timeout: TimeInterval? = nil) async throws {
        try requireConnected()
        _ = try await peer.sendRequest(
            method: "resources/unsubscribe", params: UnsubscribeRequest(uri: uri),
            as: EmptyResult.self, timeout: timeout)
    }

    // MARK: - prompts

    /// Lists all prompts, following `nextCursor` pagination until exhausted.
    public func listPrompts(timeout: TimeInterval? = nil) async throws -> [Prompt] {
        var prompts: [Prompt] = []
        var cursor: String?
        repeat {
            let result = try await listPromptsPage(cursor: cursor, timeout: timeout)
            prompts.append(contentsOf: result.prompts)
            cursor = result.nextCursor
        } while cursor != nil
        return prompts
    }

    /// Fetches a single `prompts/list` page.
    public func listPromptsPage(
        cursor: String? = nil, timeout: TimeInterval? = nil
    ) async throws -> ListPromptsResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.prompts != nil, "server does not advertise 'prompts'")
        return try await peer.sendRequest(
            method: "prompts/list", params: ListPromptsRequest(cursor: cursor),
            as: ListPromptsResult.self, timeout: timeout)
    }

    /// Renders a prompt with the given arguments.
    public func getPrompt(
        name: String,
        arguments: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (ProgressNotification) async -> Void)? = nil
    ) async throws -> GetPromptResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.prompts != nil, "server does not advertise 'prompts'")
        let token = registerProgressHandler(onProgress)
        defer { unregisterProgressHandler(token) }
        let request = GetPromptRequest(
            name: name, arguments: arguments,
            meta: token.map { RequestMeta(progressToken: $0) })
        return try await peer.sendRequest(
            method: "prompts/get", params: request, as: GetPromptResult.self, timeout: timeout)
    }

    // MARK: - logging & completion

    /// Sets the server's minimum log level for `notifications/message`.
    public func setLogLevel(
        _ level: LoggingLevel, timeout: TimeInterval? = nil
    ) async throws {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.logging != nil, "server does not advertise 'logging'")
        _ = try await peer.sendRequest(
            method: "logging/setLevel", params: SetLevelRequest(level: level),
            as: EmptyResult.self, timeout: timeout)
    }

    /// Asks the server to autocomplete an argument value for a prompt or resource.
    public func complete(
        ref: CompletionReference,
        argumentName: String,
        value: String,
        timeout: TimeInterval? = nil
    ) async throws -> CompleteResult {
        try requireConnected()
        try requireServerCapability(
            serverCapabilitiesValue?.completions != nil,
            "server does not advertise 'completions'")
        let request = CompleteRequest(
            ref: ref, argument: CompleteArgument(name: argumentName, value: value))
        return try await peer.sendRequest(
            method: "completion/complete", params: request, as: CompleteResult.self,
            timeout: timeout)
    }

    // MARK: - roots

    /// Emits `notifications/roots/list_changed`: this client's workspace roots have
    /// changed, servers should re-fetch.
    public func notifyRootsListChanged() async throws {
        try requireConnected()
        try await peer.sendNotification(
            method: "notifications/roots/list_changed", params: EmptyResult())
    }

    // MARK: - Handler registration

    private func registerHandlers() async {
        await peer.onRequest(method: "ping") { _ in
            try JSONValue(encoding: EmptyResult())
        }
        await peer.onRequest(method: "roots/list") { [weak self] params in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.handleListRoots(params)
        }
        await peer.onRequest(method: "sampling/createMessage") { [weak self] params in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.handleCreateMessage(params)
        }
        await peer.onRequest(method: "elicitation/create") { [weak self] params in
            guard let self else { throw MCPError.connectionClosed }
            return try await self.handleElicit(params)
        }
        await peer.onNotification(method: "notifications/tools/list_changed") { [weak self] _ in
            await self?.handleToolsListChanged()
        }
        await peer.onNotification(method: "notifications/resources/list_changed") {
            [weak self] _ in
            await self?.handleResourceListChanged()
        }
        await peer.onNotification(method: "notifications/resources/updated") {
            [weak self] params in
            await self?.handleResourceUpdated(params)
        }
        await peer.onNotification(method: "notifications/prompts/list_changed") {
            [weak self] _ in
            await self?.handlePromptsListChanged()
        }
        await peer.onNotification(method: "notifications/message") { [weak self] params in
            await self?.handleLogMessage(params)
        }
        await peer.onNotification(method: "notifications/progress") { [weak self] params in
            await self?.handleProgress(params)
        }
    }

    // MARK: - Incoming requests

    private func handleListRoots(_ paramsValue: JSONValue?) async throws -> JSONValue {
        let request = try decode(ListRootsRequest.self, from: paramsValue)
        guard let delegate else { return try JSONValue(encoding: ListRootsResult()) }
        let result = try await delegate.listRoots(request)
        return try JSONValue(encoding: result)
    }

    private func handleCreateMessage(_ paramsValue: JSONValue?) async throws -> JSONValue {
        guard let delegate else { throw MCPError.methodNotSupported("sampling/createMessage") }
        let request = try decode(CreateMessageRequest.self, from: paramsValue)
        let result = try await delegate.createMessage(request)
        return try JSONValue(encoding: result)
    }

    private func handleElicit(_ paramsValue: JSONValue?) async throws -> JSONValue {
        guard let delegate else { throw MCPError.methodNotSupported("elicitation/create") }
        let request = try decode(ElicitRequest.self, from: paramsValue)
        let result = try await delegate.elicit(request)
        return try JSONValue(encoding: result)
    }

    // MARK: - Incoming notifications

    private func handleToolsListChanged() async {
        await delegate?.toolsListChanged()
    }

    private func handleResourceListChanged() async {
        await delegate?.resourceListChanged()
    }

    private func handleResourceUpdated(_ paramsValue: JSONValue?) async {
        guard let notification = try? decode(ResourceUpdatedNotification.self, from: paramsValue)
        else {
            logger.warning("Received malformed notifications/resources/updated")
            return
        }
        await delegate?.resourceUpdated(uri: notification.uri)
    }

    private func handlePromptsListChanged() async {
        await delegate?.promptsListChanged()
    }

    private func handleLogMessage(_ paramsValue: JSONValue?) async {
        guard let notification = try? decode(LogMessageNotification.self, from: paramsValue)
        else {
            logger.warning("Received malformed notifications/message")
            return
        }
        await delegate?.logMessage(notification)
    }

    private func handleProgress(_ paramsValue: JSONValue?) async {
        guard let notification = try? decode(ProgressNotification.self, from: paramsValue) else {
            logger.warning("Received malformed notifications/progress")
            return
        }
        await progressHandlers[notification.progressToken]?(notification)
    }

    // MARK: - Progress bookkeeping

    private func registerProgressHandler(
        _ handler: (@Sendable (ProgressNotification) async -> Void)?
    ) -> ProgressToken? {
        guard let handler else { return nil }
        let token = ProgressToken.number(nextProgressTokenNumber)
        nextProgressTokenNumber += 1
        progressHandlers[token] = handler
        return token
    }

    private func unregisterProgressHandler(_ token: ProgressToken?) {
        guard let token else { return }
        progressHandlers[token] = nil
    }

    // MARK: - Guards

    private func requireConnected() throws {
        guard connected else { throw MCPError.notConnected }
    }

    private func requireServerCapability(_ supported: Bool, _ description: String) throws {
        guard supported else { throw MCPError.capabilityNotSupported(description) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from paramsValue: JSONValue?) throws -> T {
        try (paramsValue ?? .object([:])).decode(as: T.self)
    }
}
