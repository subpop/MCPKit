import Foundation
import JSONRPCKit
import Synchronization
import Testing

@testable import MCPKit

// MARK: - Loopback client ↔ server

/// Full flows over an in-memory loopback pair: MCPKit `Client` speaking to
/// MCPKit `Server`, both sides live in the same process.
struct EndToEndLoopbackTests {
    /// Starts a server on one end of a fresh loopback pair and returns the
    /// client-facing transport plus the server.
    private func makePair(
        delegate: ServerDelegate,
        clientDelegate: (any ClientDelegate)? = nil
    ) -> (client: Client, server: Server) {
        let (clientEnd, serverEnd) = makeLoopbackPair()
        let server = Server(transport: serverEnd, delegate: delegate)
        let client = Client(transport: clientEnd, delegate: clientDelegate)
        return (client, server)
    }

    @Test("initialize handshake completes on both sides")
    func handshake() async throws {
        let delegate = RecordingServer()
        let (client, server) = makePair(delegate: delegate)

        async let started: Void = server.run()
        let result = try await client.connect(timeout: 5)
        await server.close()

        #expect(result.protocolVersion == latestMCPProtocolVersion)
        #expect(result.serverInfo.name == "recording-server")
        #expect(await client.serverInfo?.name == "recording-server")
        #expect(await server.clientInfo?.name == "MCPKit")
        #expect(await server.isInitialized)
        _ = try await started
    }

    @Test("tools flow end to end, including progress")
    func toolsFlow() async throws {
        let delegate = RecordingServer(toolkit: RecordingServer.Toolkit(reportProgress: true))
        let (client, server) = makePair(delegate: delegate)

        async let started: Void = server.run()
        _ = try await client.connect(timeout: 5)

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo"])

        let progress = Mutex<[ProgressNotification]>([])
        let result = try await client.callTool(
            name: "echo", arguments: ["text": .string("round trip")]
        ) { notification in
            progress.withLock { $0.append(notification) }
        }
        #expect(result.content == [.text("round trip")])
        #expect(!result.isError)

        let updates = progress.withLock { $0 }
        #expect(updates.count == 1)
        #expect(updates.first?.progress == 0.5)
        #expect(updates.first?.total == 1.0)
        #expect(updates.first?.message == "halfway")

        await server.close()
        _ = try await started
    }

    @Test("server-initiated roots/list reaches the client delegate")
    func serverToClientRequest() async throws {
        final class RootsClient: ClientDelegate {
            let capabilities = ClientCapabilities(roots: RootsCapability())
            func listRoots(_ request: ListRootsRequest) async throws -> ListRootsResult {
                ListRootsResult(roots: [Root(uri: "file:///project", name: "project")])
            }
        }
        let (client, server) = makePair(delegate: RecordingServer(), clientDelegate: RootsClient())

        async let started: Void = server.run()
        _ = try await client.connect(timeout: 5)

        let roots = try await server.listRoots(timeout: 5)
        #expect(roots.roots.map(\.uri) == ["file:///project"])

        await server.close()
        _ = try await started
        _ = client
    }

    @Test("server-initiated requests are capability-gated")
    func serverToClientCapabilityGate() async throws {
        let (client, server) = makePair(delegate: RecordingServer())

        async let started: Void = server.run()
        _ = try await client.connect(timeout: 5)

        // The (default) client delegate does not advertise roots.
        await #expect(throws: MCPError.capabilityNotSupported("client does not advertise 'roots'")) {
            _ = try await server.listRoots(timeout: 5)
        }
        await #expect(throws: MCPError.capabilityNotSupported("client does not advertise 'sampling'")) {
            _ = try await server.createMessage(
                CreateMessageRequest(
                    messages: [SamplingMessage(role: .user, content: .text("hi"))],
                    maxTokens: 10),
                timeout: 5)
        }

        await server.close()
        _ = try await started
        _ = client
    }

    @Test("list-changed notifications reach the client delegate")
    func listChangedNotifications() async throws {
        final class NotingClient: ClientDelegate {
            let noted = Mutex<[String]>([])
            func toolsListChanged() async {
                noted.withLock { $0.append("tools") }
            }
        }
        let delegate = RecordingServer()
        let clientDelegate = NotingClient()
        let (clientEnd, serverEnd) = makeLoopbackPair()
        let server = Server(transport: serverEnd, delegate: delegate)
        let client = Client(transport: clientEnd, delegate: clientDelegate)

        async let started: Void = server.run()
        _ = try await client.connect(timeout: 5)

        try await server.notifyToolsListChanged()
        try await waitFor { !clientDelegate.noted.withLock { $0 }.isEmpty }
        #expect(clientDelegate.noted.withLock { $0 } == ["tools"])

        await server.close()
        _ = try await started
    }

    @Test("ping works in both directions")
    func pingBothDirections() async throws {
        let (client, server) = makePair(delegate: RecordingServer())

        async let started: Void = server.run()
        _ = try await client.connect(timeout: 5)

        try await client.ping(timeout: 5)
        try await server.ping(timeout: 5)

        await server.close()
        _ = try await started
    }
}

// MARK: - Subprocess

/// Locates the built MCPEchoServer binary for the subprocess fixture, checking
/// both the classic and Xcode-style SwiftPM build layouts.
private let echoServerBinary: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // EndToEndTests.swift
        .deletingLastPathComponent()  // MCPKitTests/
        .deletingLastPathComponent()  // Tests/
    let candidates = [
        packageRoot.appending(path: ".build/out/Products/Debug/MCPEchoServer"),
        packageRoot.appending(path: ".build/debug/MCPEchoServer"),
        packageRoot.appending(path: ".build/arm64-apple-macosx/debug/MCPEchoServer"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
}()

/// The example MCPEchoServer executable, spawned as a real subprocess and driven
/// by a `Client` over stdio — the full production path including `ProcessTransport`.
struct EndToEndSubprocessTests {
    @Test(
        "full session against the MCPEchoServer subprocess",
        .disabled(if: echoServerBinary == nil, "MCPEchoServer binary is not built")
    )
    func echoServerSession() async throws {
        guard let binary = echoServerBinary else { return }

        let client = try Client(command: binary.path(percentEncoded: false))
        defer { Task { await client.close() } }

        let initialized = try await client.connect(timeout: 30)
        #expect(initialized.protocolVersion == latestMCPProtocolVersion)
        #expect(initialized.serverInfo.name == "MCPEchoServer")

        // Round-trip liveness.
        try await client.ping(timeout: 10)

        // Tool listing.
        let tools = try await client.listTools(timeout: 10)
        #expect(Set(tools.map(\.name)) == ["echo", "add"])

        // Tool call with progress updates.
        let progress = Mutex<[ProgressNotification]>([])
        let echoed = try await client.callTool(
            name: "echo", arguments: ["text": .string("hello subprocess")], timeout: 10
        ) { notification in
            progress.withLock { $0.append(notification) }
        }
        #expect(echoed.content == [.text("hello subprocess")])
        #expect(!echoed.isError)
        #expect(progress.withLock { $0 }.count == 1)

        // Structured output.
        let added = try await client.callTool(
            name: "add", arguments: ["a": .number(2), "b": .number(40)], timeout: 10)
        guard case .number(let sum)? = added.structuredContent?.objectValue?["sum"] else {
            Issue.record("expected structured sum, got \(String(describing: added.structuredContent))")
            return
        }
        #expect(sum == 42)
        #expect(added.combinedText == "42")

        await client.close()
    }

    @Test(
        "client disconnect terminates the server subprocess cleanly",
        .disabled(if: echoServerBinary == nil, "MCPEchoServer binary is not built")
    )
    func disconnectTerminatesServer() async throws {
        guard let binary = echoServerBinary else { return }

        let client = try Client(command: binary.path(percentEncoded: false))
        _ = try await client.connect(timeout: 30)
        // Closing the client closes the pipes; the server observes EOF, drains,
        // and exits. Nothing here can hang, which is the assertion.
        await client.close()
    }
}
