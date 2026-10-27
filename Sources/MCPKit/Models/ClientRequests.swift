import Foundation
import JSONRPCKit

// MARK: - roots/list (server → client)

/// The `roots/list` request: the server asks the client for its workspace roots.
public struct ListRootsRequest: Sendable, Equatable, Codable {
    public var meta: RequestMeta?

    public init(meta: RequestMeta? = nil) {
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

/// A workspace root exposed by the client.
public struct Root: Sendable, Equatable, Codable {
    public var uri: String
    public var name: String?
    public var meta: JSONValue?

    public init(uri: String, name: String? = nil, meta: JSONValue? = nil) {
        self.uri = uri
        self.name = name
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri, name
        case meta = "_meta"
    }
}

public struct ListRootsResult: Sendable, Equatable, Codable {
    public var roots: [Root]
    public var meta: JSONValue?

    public init(roots: [Root] = [], meta: JSONValue? = nil) {
        self.roots = roots
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roots = try container.decode([Root].self, forKey: .roots, default: [])
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    enum CodingKeys: String, CodingKey {
        case roots
        case meta = "_meta"
    }
}

// MARK: - sampling/createMessage (server → client)

/// One message in a sampling request's conversation history.
public struct SamplingMessage: Sendable, Equatable, Codable {
    public var role: Role
    public var content: Content

    public init(role: Role, content: Content) {
        self.role = role
        self.content = content
    }
}

/// How much of the server's context the client's model should include.
public enum IncludeContext: String, Sendable, Equatable, Codable {
    case none
    case thisServer
    case allServers
}

/// The `sampling/createMessage` request: the server asks the client's LLM to generate
/// a message. Requires the client's `sampling` capability.
public struct CreateMessageRequest: Sendable, Equatable, Codable {
    public var messages: [SamplingMessage]
    public var systemPrompt: String?
    public var includeContext: IncludeContext?
    /// Maximum number of tokens to sample, required.
    public var maxTokens: Int
    public var temperature: Double?
    public var stopSequences: [String]?
    public var meta: RequestMeta?

    public init(
        messages: [SamplingMessage],
        systemPrompt: String? = nil,
        includeContext: IncludeContext? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        stopSequences: [String]? = nil,
        meta: RequestMeta? = nil
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.includeContext = includeContext
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case messages, systemPrompt, includeContext, maxTokens, temperature, stopSequences
        case meta = "_meta"
    }
}

public struct CreateMessageResult: Sendable, Equatable, Codable {
    public var role: Role
    public var content: Content
    /// Name of the model that generated the message.
    public var model: String
    /// Why sampling stopped, e.g. `endTurn`, `maxTokens`, `stopSequence`.
    public var stopReason: String?
    public var stopSequence: String?
    public var meta: JSONValue?

    public init(
        role: Role,
        content: Content,
        model: String,
        stopReason: String? = nil,
        stopSequence: String? = nil,
        meta: JSONValue? = nil
    ) {
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case role, content, model, stopReason, stopSequence
        case meta = "_meta"
    }
}

// MARK: - elicitation/create (server → client)

/// The `elicitation/create` request: the server asks the client to gather structured
/// input from the user via a form described by `requestedSchema` (a JSON Schema).
/// Requires the client's `elicitation` capability.
public struct ElicitRequest: Sendable, Equatable, Codable {
    public var message: String
    public var requestedSchema: JSONValue
    public var meta: RequestMeta?

    public init(message: String, requestedSchema: JSONValue, meta: RequestMeta? = nil) {
        self.message = message
        self.requestedSchema = requestedSchema
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case message, requestedSchema
        case meta = "_meta"
    }
}

/// The user's decision on an elicitation request.
public enum ElicitAction: String, Sendable, Equatable, Codable {
    case accept
    case decline
    case cancel
}

public struct ElicitResult: Sendable, Equatable, Codable {
    public var action: ElicitAction
    /// Form values keyed by property name, when `action` is `accept`.
    public var content: Content?
    public var meta: JSONValue?

    public init(action: ElicitAction, content: Content? = nil, meta: JSONValue? = nil) {
        self.action = action
        self.content = content
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case action, content
        case meta = "_meta"
    }
}
