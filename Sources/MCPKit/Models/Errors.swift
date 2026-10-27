import Foundation
import JSONRPCKit

/// Errors thrown by ``Client`` and ``Server``.
///
/// Cases raised while answering an incoming request conform to JSONRPCKit's
/// `JSONRPCErrorConvertible` protocol so they map to specific JSON-RPC error codes
/// instead of a generic `-32603`; any other error thrown from a handler is reported
/// to the peer as an internal error.
public enum MCPError: Error, Sendable, Equatable, LocalizedError, JSONRPCErrorConvertible {
    /// An operation was attempted before `connect()`/`start()` completed the handshake.
    case notConnected
    /// The transport closed mid-request, or the connection is gone.
    case connectionClosed
    /// A request arrived before `initialize` (JSON-RPC `-32002`).
    case serverNotInitialized
    /// The peer answered `initialize` with a protocol version this package cannot speak.
    case unsupportedProtocolVersion(String)
    /// The peer did not advertise the capability an operation requires.
    case capabilityNotSupported(String)
    /// The delegate does not implement the requested method (JSON-RPC `-32601`).
    case methodNotSupported(String)
    /// A request payload could not be decoded, or is otherwise invalid (JSON-RPC `-32602`).
    case invalidParams(String)
    /// A client configuration was malformed (e.g. an empty stdio command).
    case invalidConfiguration(String)
    /// A peer's response could not be decoded into the expected type.
    case invalidResponse(String)

    public var errorCode: Int {
        switch self {
        case .methodNotSupported:
            return -32601
        case .invalidParams, .invalidConfiguration, .invalidResponse, .unsupportedProtocolVersion:
            return -32602
        case .notConnected, .connectionClosed, .capabilityNotSupported:
            return -32000
        case .serverNotInitialized:
            return -32002
        }
    }

    public var errorMessage: String {
        switch self {
        case .notConnected:
            return "Not connected: perform the initialize handshake first"
        case .connectionClosed:
            return "Connection closed"
        case .serverNotInitialized:
            return "Server not initialized"
        case .unsupportedProtocolVersion(let version):
            return "Unsupported MCP protocol version: \(version)"
        case .capabilityNotSupported(let message):
            return "Capability not supported: \(message)"
        case .methodNotSupported(let method):
            return "Method not supported: \(method)"
        case .invalidParams(let message):
            return "Invalid params: \(message)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        }
    }

    public var errorDescription: String? { errorMessage }
}
