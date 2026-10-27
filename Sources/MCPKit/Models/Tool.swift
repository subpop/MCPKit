import Foundation
import JSONRPCKit

// MARK: - Tool

/// A tool exposed by a server via `tools/list`.
public struct Tool: Sendable, Equatable, Codable {
    public var name: String
    public var title: String?
    public var description: String?
    /// A JSON Schema object describing the tool's `arguments`.
    public var inputSchema: JSONValue
    /// A JSON Schema object describing the tool's structured output (2025-06-18).
    public var outputSchema: JSONValue?
    public var annotations: ToolAnnotations?
    public var icons: [Icon]?
    public var meta: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema, annotations, icons
        case meta = "_meta"
    }

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object([:]),
        outputSchema: JSONValue? = nil,
        annotations: ToolAnnotations? = nil,
        icons: [Icon]? = nil,
        meta: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.icons = icons
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(JSONValue.self, forKey: .inputSchema, default: .object([:]))
        outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        annotations = try container.decodeIfPresent(ToolAnnotations.self, forKey: .annotations)
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }
}

/// Optional behavioral hints a server attaches to a ``Tool``.
public struct ToolAnnotations: Sendable, Equatable, Codable {
    public var title: String?
    /// If true, the tool does not modify its environment. Defaults to false.
    public var readOnlyHint: Bool
    /// If true, the tool may destructively modify its environment. Defaults to true.
    public var destructiveHint: Bool
    /// If true, calling the tool repeatedly with the same arguments has no additional
    /// effect. Defaults to false.
    public var idempotentHint: Bool
    /// If true, the tool may interact with an "open world" of external entities.
    /// Defaults to true.
    public var openWorldHint: Bool

    public init(
        title: String? = nil,
        readOnlyHint: Bool = false,
        destructiveHint: Bool = true,
        idempotentHint: Bool = false,
        openWorldHint: Bool = true
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        readOnlyHint = try container.decode(Bool.self, forKey: .readOnlyHint, default: false)
        destructiveHint = try container.decode(Bool.self, forKey: .destructiveHint, default: true)
        idempotentHint = try container.decode(Bool.self, forKey: .idempotentHint, default: false)
        openWorldHint = try container.decode(Bool.self, forKey: .openWorldHint, default: true)
    }
}

// MARK: - tools/list

public struct ListToolsRequest: Sendable, Equatable, Codable {
    /// Opaque cursor from a previous page's `nextCursor`.
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

public struct ListToolsResult: Sendable, Equatable, Codable {
    public var tools: [Tool]
    public var nextCursor: String?

    public init(tools: [Tool] = [], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([Tool].self, forKey: .tools, default: [])
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - tools/call

public struct CallToolRequest: Sendable, Equatable, Codable {
    public var name: String
    public var arguments: [String: JSONValue]?
    public var meta: RequestMeta?

    public init(name: String, arguments: [String: JSONValue]? = nil, meta: RequestMeta? = nil) {
        self.name = name
        self.arguments = arguments
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case name, arguments
        case meta = "_meta"
    }
}

public struct CallToolResult: Sendable, Equatable, Codable {
    public var content: [Content]
    /// Structured output matching the tool's `outputSchema`, when declared (2025-06-18).
    public var structuredContent: JSONValue?
    /// Whether the tool executed but reported an error. Defaults to false.
    public var isError: Bool
    public var meta: JSONValue?

    public init(
        content: [Content] = [],
        structuredContent: JSONValue? = nil,
        isError: Bool = false,
        meta: JSONValue? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode([Content].self, forKey: .content, default: [])
        structuredContent = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        isError = try container.decode(Bool.self, forKey: .isError, default: false)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    /// Concatenated text of all content items that carry text.
    public var combinedText: String {
        content.compactMap(\.textValue).joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
        case meta = "_meta"
    }
}

// MARK: - Content blocks

/// A content item in tool results, prompt messages, sampling messages, and elicitation
/// responses. `text`, `image`, `audio`, `resource` (embedded contents), and
/// `resource_link` are decoded structurally; any other `type` is preserved verbatim as
/// `unknown` so future content kinds survive the round-trip.
public enum Content: Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String)
    case audio(data: String, mimeType: String)
    case resource(ResourceContents)
    case resourceLink(ResourceLink)
    case unknown(JSONValue)
}

extension Content: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource
    }

    public init(from decoder: Decoder) throws {
        // Peek at the discriminator first, keeping the raw value for fallback.
        let raw = try JSONValue(from: decoder)
        guard let object = raw.objectValue,
            let type = object["type"]?.stringValue
        else {
            self = .unknown(raw)
            return
        }
        switch type {
        case "text":
            self = .text(try raw.decode(as: TextContentPayload.self).text)
        case "image":
            let payload = try raw.decode(as: DataContentPayload.self)
            self = .image(data: payload.data, mimeType: payload.mimeType)
        case "audio":
            let payload = try raw.decode(as: DataContentPayload.self)
            self = .audio(data: payload.data, mimeType: payload.mimeType)
        case "resource":
            self = .resource(try raw.decode(as: ResourceContentPayload.self).resource)
        case "resource_link":
            self = .resourceLink(try raw.decode(as: ResourceLink.self))
        default:
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            try TextContentPayload(text: text).encode(to: encoder)
        case .image(let data, let mimeType):
            try DataContentPayload(type: "image", data: data, mimeType: mimeType)
                .encode(to: encoder)
        case .audio(let data, let mimeType):
            try DataContentPayload(type: "audio", data: data, mimeType: mimeType)
                .encode(to: encoder)
        case .resource(let resource):
            try ResourceContentPayload(resource: resource).encode(to: encoder)
        case .resourceLink(let link):
            try link.encode(to: encoder)
        case .unknown(let raw):
            try raw.encode(to: encoder)
        }
    }

    /// Best-effort plain-text rendering of this content item, if it has one.
    public var textValue: String? {
        switch self {
        case .text(let text):
            return text
        case .unknown(let raw):
            return raw.objectValue?["text"]?.stringValue
        default:
            return nil
        }
    }
}

private struct TextContentPayload: Codable {
    var type: String = "text"
    var text: String
}

private struct DataContentPayload: Codable {
    var type: String
    var data: String
    var mimeType: String
}

private struct ResourceContentPayload: Codable {
    var type: String = "resource"
    var resource: ResourceContents
}
