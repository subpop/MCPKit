import Foundation
import JSONRPCKit

// MARK: - completion/complete

/// A reference to the prompt or resource whose argument is being completed.
public enum CompletionReference: Sendable, Equatable {
    case prompt(name: String)
    case resource(uri: String)

    /// A reference to a prompt by name.
    public static func prompt(_ name: String) -> CompletionReference {
        .prompt(name: name)
    }

    /// A reference to a resource by URI.
    public static func resource(_ uri: String) -> CompletionReference {
        .resource(uri: uri)
    }
}

extension CompletionReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, name, uri
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let type = raw.objectValue?["type"]?.stringValue else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "CompletionReference requires a \"type\" field"))
        }
        switch type {
        case "ref/prompt":
            self = .prompt(name: try raw.decode(as: PromptRefPayload.self).name)
        case "ref/resource":
            self = .resource(uri: try raw.decode(as: ResourceRefPayload.self).uri)
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown CompletionReference type: \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .prompt(let name):
            try PromptRefPayload(name: name).encode(to: encoder)
        case .resource(let uri):
            try ResourceRefPayload(uri: uri).encode(to: encoder)
        }
    }
}

private struct PromptRefPayload: Codable {
    var type: String = "ref/prompt"
    var name: String
}

private struct ResourceRefPayload: Codable {
    var type: String = "ref/resource"
    var uri: String
}

/// The argument being completed.
public struct CompleteArgument: Sendable, Equatable, Codable {
    public var name: String
    /// The (possibly partial) value entered so far.
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CompleteRequest: Sendable, Equatable, Codable {
    public var ref: CompletionReference
    public var argument: CompleteArgument
    public var meta: RequestMeta?

    public init(ref: CompletionReference, argument: CompleteArgument, meta: RequestMeta? = nil) {
        self.ref = ref
        self.argument = argument
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case ref, argument
        case meta = "_meta"
    }
}

public struct CompleteResult: Sendable, Equatable, Codable {
    /// Suggested completions. Must not exceed 100 entries.
    public var values: [String]
    /// Total number of completions available, when known.
    public var total: Int?
    /// Whether more completions exist beyond `values`. Defaults to false.
    public var hasMore: Bool
    public var meta: JSONValue?

    public init(values: [String] = [], total: Int? = nil, hasMore: Bool = false, meta: JSONValue? = nil) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([String].self, forKey: .values, default: [])
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        hasMore = try container.decode(Bool.self, forKey: .hasMore, default: false)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    enum CodingKeys: String, CodingKey {
        case values, total, hasMore
        case meta = "_meta"
    }
}
