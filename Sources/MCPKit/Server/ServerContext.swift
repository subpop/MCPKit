import Foundation
import JSONRPCKit

/// Per-request context handed to ``ServerDelegate`` handlers. Carries the progress
/// token the client attached to the request (if any) and sends `notifications/progress`
/// updates for it.
public struct ServerContext: Sendable {
    private let peer: JSONRPCPeer

    /// The progress token the client attached to the in-flight request, or `nil` when
    /// the client did not request progress updates.
    public let progressToken: ProgressToken?

    init(peer: JSONRPCPeer, progressToken: ProgressToken?) {
        self.peer = peer
        self.progressToken = progressToken
    }

    /// Reports progress for the in-flight request. No-op when the client did not attach
    /// a progress token.
    ///
    /// - Parameters:
    ///   - progress: Monotonically increasing progress value.
    ///   - total: Total the progress value is relative to, when known.
    ///   - message: Human-readable progress message.
    public func reportProgress(
        _ progress: Double, total: Double? = nil, message: String? = nil
    ) async throws {
        guard let progressToken else { return }
        let notification = ProgressNotification(
            progressToken: progressToken, progress: progress, total: total, message: message)
        try await peer.sendNotification(method: "notifications/progress", params: notification)
    }
}
