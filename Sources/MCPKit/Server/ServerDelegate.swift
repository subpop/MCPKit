import Foundation

/// The interface an MCP server implementation provides. Conforming types are wrapped by
/// ``Server`` to serve requests from a connected client over a `Transport`.
///
/// Only ``capabilities`` and ``info`` are required. Handlers are registered by
/// ``Server`` solely for the capabilities you advertise, and every handler below
/// defaults to throwing ``MCPError/methodNotSupported(_:)``; override only what the
/// advertised capabilities promise.
public protocol ServerDelegate: Sendable {
    /// Capabilities this server supports, returned in the `initialize` response.
    var capabilities: ServerCapabilities { get }
    /// Implementation metadata, returned in the `initialize` response.
    var info: Implementation { get }
    /// Optional human-facing usage instructions, returned in the `initialize` response.
    var instructions: String? { get }

    /// Handles `tools/list`.
    func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult

    /// Handles `tools/call`.
    func callTool(_ request: CallToolRequest, context: ServerContext) async throws -> CallToolResult

    /// Handles `resources/list`.
    func listResources(_ request: ListResourcesRequest) async throws -> ListResourcesResult

    /// Handles `resources/templates/list`.
    func listResourceTemplates(
        _ request: ListResourceTemplatesRequest
    ) async throws -> ListResourceTemplatesResult

    /// Handles `resources/read`.
    func readResource(
        _ request: ReadResourceRequest, context: ServerContext
    ) async throws -> ReadResourceResult

    /// Handles `resources/subscribe`.
    func subscribe(_ request: SubscribeRequest) async throws

    /// Handles `resources/unsubscribe`.
    func unsubscribe(_ request: UnsubscribeRequest) async throws

    /// Handles `prompts/list`.
    func listPrompts(_ request: ListPromptsRequest) async throws -> ListPromptsResult

    /// Handles `prompts/get`.
    func getPrompt(_ request: GetPromptRequest, context: ServerContext) async throws -> GetPromptResult

    /// Handles `completion/complete`.
    func complete(_ request: CompleteRequest) async throws -> CompleteResult

    /// Handles `logging/setLevel`.
    func setLogLevel(_ request: SetLevelRequest) async

    /// Handles the `notifications/roots/list_changed` notification from the client.
    func rootsListChanged() async
}

extension ServerDelegate {
    public var instructions: String? { nil }

    public func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult {
        throw MCPError.methodNotSupported("tools/list")
    }

    public func callTool(
        _ request: CallToolRequest, context: ServerContext
    ) async throws -> CallToolResult {
        throw MCPError.methodNotSupported("tools/call")
    }

    public func listResources(_ request: ListResourcesRequest) async throws -> ListResourcesResult {
        throw MCPError.methodNotSupported("resources/list")
    }

    public func listResourceTemplates(
        _ request: ListResourceTemplatesRequest
    ) async throws -> ListResourceTemplatesResult {
        throw MCPError.methodNotSupported("resources/templates/list")
    }

    public func readResource(
        _ request: ReadResourceRequest, context: ServerContext
    ) async throws -> ReadResourceResult {
        throw MCPError.methodNotSupported("resources/read")
    }

    public func subscribe(_ request: SubscribeRequest) async throws {
        throw MCPError.methodNotSupported("resources/subscribe")
    }

    public func unsubscribe(_ request: UnsubscribeRequest) async throws {
        throw MCPError.methodNotSupported("resources/unsubscribe")
    }

    public func listPrompts(_ request: ListPromptsRequest) async throws -> ListPromptsResult {
        throw MCPError.methodNotSupported("prompts/list")
    }

    public func getPrompt(
        _ request: GetPromptRequest, context: ServerContext
    ) async throws -> GetPromptResult {
        throw MCPError.methodNotSupported("prompts/get")
    }

    public func complete(_ request: CompleteRequest) async throws -> CompleteResult {
        throw MCPError.methodNotSupported("completion/complete")
    }

    public func setLogLevel(_ request: SetLevelRequest) async {}

    public func rootsListChanged() async {}
}
