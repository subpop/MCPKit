import Foundation
import JSONRPCKit

// MARK: - Resource

/// A resource exposed by a server via `resources/list`.
public struct Resource: Sendable, Equatable, Codable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    /// Size in bytes, when known.
    public var size: Int?
    public var icons: [Icon]?
    public var meta: JSONValue?

    public init(
        uri: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        icons: [Icon]? = nil,
        meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.icons = icons
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri, name, title, description, mimeType, size, icons
        case meta = "_meta"
    }
}

/// A resource template exposing parameterized URIs via `resources/templates/list`.
public struct ResourceTemplate: Sendable, Equatable, Codable {
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?
    public var icons: [Icon]?
    public var meta: JSONValue?

    public init(
        uriTemplate: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        icons: [Icon]? = nil,
        meta: JSONValue? = nil
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.icons = icons
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uriTemplate, name, title, description, mimeType, size, icons
        case meta = "_meta"
    }
}

/// The contents of a resource, returned by `resources/read`. Text and blob resources
/// are modeled as one lenient struct: exactly one of `text` or `blob` is set per the
/// spec's one-of.
public struct ResourceContents: Sendable, Equatable, Codable {
    public var uri: String
    public var mimeType: String?
    /// UTF-8 text contents.
    public var text: String?
    /// Base64-encoded binary contents.
    public var blob: String?
    public var meta: JSONValue?

    public init(
        uri: String,
        mimeType: String? = nil,
        text: String? = nil,
        blob: String? = nil,
        meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri, mimeType, text, blob
        case meta = "_meta"
    }
}

/// A link to a resource, usable as a ``Content`` block in tool results (2025-06-18).
public struct ResourceLink: Sendable, Equatable, Codable {
    public var uri: String
    public var name: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?
    public var meta: JSONValue?

    public init(
        uri: String,
        name: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, uri, name, description, mimeType, size
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("resource_link", forKey: .type)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - resources/list

public struct ListResourcesRequest: Sendable, Equatable, Codable {
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

public struct ListResourcesResult: Sendable, Equatable, Codable {
    public var resources: [Resource]
    public var nextCursor: String?

    public init(resources: [Resource] = [], nextCursor: String? = nil) {
        self.resources = resources
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resources = try container.decode([Resource].self, forKey: .resources, default: [])
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - resources/templates/list

public struct ListResourceTemplatesRequest: Sendable, Equatable, Codable {
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

public struct ListResourceTemplatesResult: Sendable, Equatable, Codable {
    public var resourceTemplates: [ResourceTemplate]
    public var nextCursor: String?

    public init(resourceTemplates: [ResourceTemplate] = [], nextCursor: String? = nil) {
        self.resourceTemplates = resourceTemplates
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceTemplates = try container.decode(
            [ResourceTemplate].self, forKey: .resourceTemplates, default: [])
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - resources/read

public struct ReadResourceRequest: Sendable, Equatable, Codable {
    public var uri: String
    public var meta: RequestMeta?

    public init(uri: String, meta: RequestMeta? = nil) {
        self.uri = uri
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}

public struct ReadResourceResult: Sendable, Equatable, Codable {
    public var contents: [ResourceContents]
    public var meta: JSONValue?

    public init(contents: [ResourceContents] = [], meta: JSONValue? = nil) {
        self.contents = contents
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contents = try container.decode([ResourceContents].self, forKey: .contents, default: [])
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    enum CodingKeys: String, CodingKey {
        case contents
        case meta = "_meta"
    }
}

// MARK: - resources/subscribe

public struct SubscribeRequest: Sendable, Equatable, Codable {
    public var uri: String
    public var meta: RequestMeta?

    public init(uri: String, meta: RequestMeta? = nil) {
        self.uri = uri
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}

public struct UnsubscribeRequest: Sendable, Equatable, Codable {
    public var uri: String
    public var meta: RequestMeta?

    public init(uri: String, meta: RequestMeta? = nil) {
        self.uri = uri
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}

// MARK: - notifications/resources/updated

/// The payload of `notifications/resources/updated`, identifying a changed resource.
public struct ResourceUpdatedNotification: Sendable, Equatable, Codable {
    public var uri: String
    public var meta: JSONValue?

    public init(uri: String, meta: JSONValue? = nil) {
        self.uri = uri
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}
