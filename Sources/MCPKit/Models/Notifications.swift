import Foundation
import JSONRPCKit

// MARK: - Progress

/// A progress token, attached by the caller in a request's `_meta.progressToken` and
/// echoed by the callee in `notifications/progress` to associate updates with the
/// in-flight request.
public enum ProgressToken: Sendable, Equatable, Hashable, Codable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

extension ProgressToken: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ProgressToken: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(value) }
}

/// The `_meta` object attached to outgoing requests. MCPKit uses it to carry
/// `progressToken`; unknown keys received from a peer are ignored.
public struct RequestMeta: Sendable, Equatable, Codable {
    public var progressToken: ProgressToken?

    public init(progressToken: ProgressToken? = nil) {
        self.progressToken = progressToken
    }
}

/// A `notifications/progress` update for an in-flight request, associated by
/// `progressToken`.
public struct ProgressNotification: Sendable, Equatable, Codable {
    public var progressToken: ProgressToken
    /// Monotonically increasing progress value.
    public var progress: Double
    /// Total the progress value is relative to, when known.
    public var total: Double?
    /// Human-readable progress message.
    public var message: String?
    public var meta: JSONValue?

    public init(
        progressToken: ProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil,
        meta: JSONValue? = nil
    ) {
        self.progressToken = progressToken
        self.progress = progress
        self.total = total
        self.message = message
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case progressToken, progress, total, message
        case meta = "_meta"
    }
}
