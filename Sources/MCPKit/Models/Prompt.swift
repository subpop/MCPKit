import Foundation
import JSONRPCKit

// MARK: - Prompt

/// A prompt exposed by a server via `prompts/list`.
public struct Prompt: Sendable, Equatable, Codable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [PromptArgument]?
    public var icons: [Icon]?
    public var meta: JSONValue?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [PromptArgument]? = nil,
        icons: [Icon]? = nil,
        meta: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.icons = icons
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case name, title, description, arguments, icons
        case meta = "_meta"
    }
}

/// An argument a ``Prompt`` accepts.
public struct PromptArgument: Sendable, Equatable, Codable {
    public var name: String
    public var title: String?
    public var description: String?
    /// Whether the argument must be provided. Defaults to false.
    public var required: Bool

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        required: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        required = try container.decode(Bool.self, forKey: .required, default: false)
    }

    enum CodingKeys: String, CodingKey { case name, title, description, required }
}

// MARK: - prompts/list

public struct ListPromptsRequest: Sendable, Equatable, Codable {
    public var cursor: String?
    public var meta: RequestMeta?

    public init(cursor: String? = nil, meta: RequestMeta? = nil) {
        self.cursor = cursor
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case cursor
        case meta = "_meta"
    }
}

public struct ListPromptsResult: Sendable, Equatable, Codable {
    public var prompts: [Prompt]
    public var nextCursor: String?

    public init(prompts: [Prompt] = [], nextCursor: String? = nil) {
        self.prompts = prompts
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try container.decode([Prompt].self, forKey: .prompts, default: [])
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - prompts/get

public struct GetPromptRequest: Sendable, Equatable, Codable {
    public var name: String
    public var arguments: [String: String]?
    public var meta: RequestMeta?

    public init(name: String, arguments: [String: String]? = nil, meta: RequestMeta? = nil) {
        self.name = name
        self.arguments = arguments
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case name, arguments
        case meta = "_meta"
    }
}

public struct GetPromptResult: Sendable, Equatable, Codable {
    public var description: String?
    public var messages: [PromptMessage]
    public var meta: JSONValue?

    public init(description: String? = nil, messages: [PromptMessage] = [], meta: JSONValue? = nil) {
        self.description = description
        self.messages = messages
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        messages = try container.decode([PromptMessage].self, forKey: .messages, default: [])
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    enum CodingKeys: String, CodingKey {
        case description, messages
        case meta = "_meta"
    }
}

/// One message in a rendered prompt.
public struct PromptMessage: Sendable, Equatable, Codable {
    public var role: Role
    public var content: Content

    public init(role: Role, content: Content) {
        self.role = role
        self.content = content
    }
}

/// The author of a message, in prompts and sampling.
public enum Role: String, Sendable, Equatable, Codable {
    case user
    case assistant
}
