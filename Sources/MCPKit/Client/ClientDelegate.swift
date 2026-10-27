import Foundation

/// The interface an MCP client implementation provides for handling server-initiated
/// requests and notifications. Conforming types are handed to ``Client``.
///
/// All methods have defaults: `ping` and `roots/list` are answered with empty results,
/// unimplemented server-initiated requests (`sampling/createMessage`,
/// `elicitation/create`) are answered with ``MCPError/methodNotSupported(_:)``, and the
/// notification hooks are no-ops. Advertise the corresponding capabilities by
/// overriding ``capabilities`` and implementing the matching methods.
public protocol ClientDelegate: Sendable {
    /// Capabilities this client supports, sent in the `initialize` request. Only
    /// advertise capabilities whose methods you implement.
    var capabilities: ClientCapabilities { get }

    /// Handles the `ping` request.
    func ping(_ request: PingRequest) async throws -> EmptyResult

    /// Handles `roots/list`: the server asks for this client's workspace roots.
    func listRoots(_ request: ListRootsRequest) async throws -> ListRootsResult

    /// Handles `sampling/createMessage`: the server asks this client's LLM to generate
    /// a message.
    func createMessage(_ request: CreateMessageRequest) async throws -> CreateMessageResult

    /// Handles `elicitation/create`: the server asks the user for structured input.
    func elicit(_ request: ElicitRequest) async throws -> ElicitResult

    /// Handles the `notifications/tools/list_changed` notification.
    func toolsListChanged() async

    /// Handles the `notifications/resources/list_changed` notification.
    func resourceListChanged() async

    /// Handles the `notifications/resources/updated` notification.
    func resourceUpdated(uri: String) async

    /// Handles the `notifications/prompts/list_changed` notification.
    func promptsListChanged() async

    /// Handles the `notifications/message` structured log notification.
    func logMessage(_ notification: LogMessageNotification) async
}

extension ClientDelegate {
    public var capabilities: ClientCapabilities { ClientCapabilities() }

    public func ping(_ request: PingRequest) async throws -> EmptyResult {
        EmptyResult()
    }

    public func listRoots(_ request: ListRootsRequest) async throws -> ListRootsResult {
        ListRootsResult()
    }

    public func createMessage(_ request: CreateMessageRequest) async throws -> CreateMessageResult {
        throw MCPError.methodNotSupported("sampling/createMessage")
    }

    public func elicit(_ request: ElicitRequest) async throws -> ElicitResult {
        throw MCPError.methodNotSupported("elicitation/create")
    }

    public func toolsListChanged() async {}

    public func resourceListChanged() async {}

    public func resourceUpdated(uri: String) async {}

    public func promptsListChanged() async {}

    public func logMessage(_ notification: LogMessageNotification) async {}
}
