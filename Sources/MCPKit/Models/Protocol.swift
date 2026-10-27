import Foundation
import JSONRPCKit

/// The MCP protocol version this package implements: proposed by ``Client`` during
/// `initialize` and echoed by ``Server`` when the requested version is supported.
public let latestMCPProtocolVersion = "2025-11-25"

/// Protocol versions this package knows how to speak.
///
/// A peer answering `initialize` with any of these is accepted (older versions proceed
/// with a logged warning); anything else is rejected with
/// ``MCPError/unsupportedProtocolVersion(_:)``.
public let knownMCPProtocolVersions: Set<String> = [
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
    "2025-11-25",
]

// MARK: - Implementation info

/// Identifying information about a client or server implementation, exchanged during
/// `initialize`.
public struct Implementation: Sendable, Equatable, Codable {
    public var name: String
    public var title: String?
    public var version: String
    public var url: String?

    public init(name: String, title: String? = nil, version: String, url: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
        self.url = url
    }
}

/// An icon attached to tools, resources, or prompts (2025-11-25). Exactly one of `data`
/// (base64-encoded image bytes) or `uri` (an image URL) should be provided.
public struct Icon: Sendable, Equatable, Codable {
    public var mimeType: String
    public var data: String?
    public var uri: String?

    public init(mimeType: String, data: String? = nil, uri: String? = nil) {
        self.mimeType = mimeType
        self.data = data
        self.uri = uri
    }
}

// MARK: - Capabilities

/// Capabilities a client advertises in its `initialize` request. Only advertise the
/// capabilities whose ``ClientDelegate`` methods you implement.
public struct ClientCapabilities: Sendable, Equatable, Codable {
    public var roots: RootsCapability?
    public var sampling: SamplingCapability?
    public var elicitation: ElicitationCapability?
    public var experimental: [String: JSONValue]?

    public init(
        roots: RootsCapability? = nil,
        sampling: SamplingCapability? = nil,
        elicitation: ElicitationCapability? = nil,
        experimental: [String: JSONValue]? = nil
    ) {
        self.roots = roots
        self.sampling = sampling
        self.elicitation = elicitation
        self.experimental = experimental
    }
}

/// The client's `roots` capability: the client exposes workspace roots to the server.
public struct RootsCapability: Sendable, Equatable, Codable {
    /// Whether the client will emit `notifications/roots/list_changed`.
    public var listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listChanged = try container.decode(Bool.self, forKey: .listChanged, default: false)
    }

    enum CodingKeys: String, CodingKey { case listChanged }
}

/// The client's `sampling` capability: the client can sample an LLM on the server's behalf.
public struct SamplingCapability: Sendable, Equatable, Codable {
    public init() {}
}

/// The client's `elicitation` capability: the client can elicit user input (forms) for
/// the server.
public struct ElicitationCapability: Sendable, Equatable, Codable {
    public init() {}
}

/// Capabilities a server advertises in its `initialize` response. ``Server`` registers
/// JSON-RPC handlers only for the capabilities the ``ServerDelegate`` declares here.
public struct ServerCapabilities: Sendable, Equatable, Codable {
    public var completions: CompletionsCapability?
    public var logging: LoggingCapability?
    public var prompts: PromptsCapability?
    public var resources: ResourcesCapability?
    public var tools: ToolsCapability?
    public var experimental: [String: JSONValue]?

    public init(
        completions: CompletionsCapability? = nil,
        logging: LoggingCapability? = nil,
        prompts: PromptsCapability? = nil,
        resources: ResourcesCapability? = nil,
        tools: ToolsCapability? = nil,
        experimental: [String: JSONValue]? = nil
    ) {
        self.completions = completions
        self.logging = logging
        self.prompts = prompts
        self.resources = resources
        self.tools = tools
        self.experimental = experimental
    }
}

/// The server's `completions` capability: argument autocompletion for prompts and resources.
public struct CompletionsCapability: Sendable, Equatable, Codable {
    public init() {}
}

/// The server's `logging` capability: the server emits `notifications/message` logs.
public struct LoggingCapability: Sendable, Equatable, Codable {
    public init() {}
}

/// The server's `prompts` capability.
public struct PromptsCapability: Sendable, Equatable, Codable {
    /// Whether the server will emit `notifications/prompts/list_changed`.
    public var listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listChanged = try container.decode(Bool.self, forKey: .listChanged, default: false)
    }

    enum CodingKeys: String, CodingKey { case listChanged }
}

/// The server's `resources` capability.
public struct ResourcesCapability: Sendable, Equatable, Codable {
    /// Whether the server supports `resources/subscribe` / `resources/unsubscribe`.
    public var subscribe: Bool
    /// Whether the server will emit `notifications/resources/list_changed`.
    public var listChanged: Bool

    public init(subscribe: Bool = false, listChanged: Bool = false) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscribe = try container.decode(Bool.self, forKey: .subscribe, default: false)
        listChanged = try container.decode(Bool.self, forKey: .listChanged, default: false)
    }

    enum CodingKeys: String, CodingKey { case subscribe, listChanged }
}

/// The server's `tools` capability.
public struct ToolsCapability: Sendable, Equatable, Codable {
    /// Whether the server will emit `notifications/tools/list_changed`.
    public var listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listChanged = try container.decode(Bool.self, forKey: .listChanged, default: false)
    }

    enum CodingKeys: String, CodingKey { case listChanged }
}

// MARK: - initialize

public struct InitializeRequest: Sendable, Equatable, Codable {
    public var protocolVersion: String
    public var capabilities: ClientCapabilities
    public var clientInfo: Implementation

    public init(
        protocolVersion: String = latestMCPProtocolVersion,
        capabilities: ClientCapabilities = ClientCapabilities(),
        clientInfo: Implementation
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

public struct InitializeResult: Sendable, Equatable, Codable {
    public var protocolVersion: String
    public var capabilities: ServerCapabilities
    public var serverInfo: Implementation
    public var instructions: String?

    public init(
        protocolVersion: String,
        capabilities: ServerCapabilities,
        serverInfo: Implementation,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

// MARK: - ping

/// The `ping` request; an empty payload used as a liveness check in both directions.
public struct PingRequest: Sendable, Equatable, Codable {
    public init() {}
}

/// A result carrying no data, used by `ping`, `logging/setLevel`,
/// `resources/subscribe`, and `resources/unsubscribe`.
public struct EmptyResult: Sendable, Equatable, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        // Accept `{}` (or any payload); nothing to decode.
        _ = try? JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object([:]).encode(to: encoder)
    }
}
