import Foundation
import JSONRPCKit

// MARK: - logging/setLevel

/// The severity levels a server may emit via `notifications/message`, ordered from most
/// to least verbose.
public enum LoggingLevel: String, Sendable, Equatable, Codable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case alert
    case emergency
}

/// The `logging/setLevel` request: the client sets the server's minimum log level.
public struct SetLevelRequest: Sendable, Equatable, Codable {
    public var level: LoggingLevel
    public var meta: RequestMeta?

    public init(level: LoggingLevel, meta: RequestMeta? = nil) {
        self.level = level
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case level
        case meta = "_meta"
    }
}

// MARK: - notifications/message

/// A structured log message emitted by the server.
public struct LogMessageNotification: Sendable, Equatable, Codable {
    public var level: LoggingLevel
    /// Name of the logger emitting the message, when the server uses multiple loggers.
    public var logger: String?
    public var data: JSONValue
    public var meta: JSONValue?

    public init(
        level: LoggingLevel,
        logger: String? = nil,
        data: JSONValue,
        meta: JSONValue? = nil
    ) {
        self.level = level
        self.logger = logger
        self.data = data
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case level, logger, data
        case meta = "_meta"
    }
}
