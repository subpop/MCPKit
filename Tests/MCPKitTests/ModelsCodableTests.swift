import Foundation
import JSONRPCKit
import Testing

@testable import MCPKit

// MARK: - Tables

struct CodableRoundTripCase: Sendable {
    var name: String
    var value: any Sendable & Codable & Equatable
}

// MARK: - Round trips

/// Table-driven Codable round-trip: encode → decode → equality, using the
/// JSON-RPC encoder/decoder that runs on the wire.
struct ModelRoundTripTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("Implementation round-trips")
    func implementation() throws {
        let value = try roundTrip(
            Implementation(name: "acme", title: "Acme", version: "2.1.0", url: "https://acme.test"))
        #expect(value == Implementation(name: "acme", title: "Acme", version: "2.1.0", url: "https://acme.test"))

        let minimal = try roundTrip(Implementation(name: "n", version: "1"))
        #expect(minimal == Implementation(name: "n", version: "1"))
    }

    @Test("Capabilities round-trip")
    func capabilities() throws {
        let client = ClientCapabilities(
            roots: RootsCapability(listChanged: true),
            sampling: SamplingCapability(),
            elicitation: ElicitationCapability())
        #expect(try roundTrip(client) == client)

        let server = ServerCapabilities(
            completions: CompletionsCapability(),
            logging: LoggingCapability(),
            prompts: PromptsCapability(listChanged: true),
            resources: ResourcesCapability(subscribe: true, listChanged: true),
            tools: ToolsCapability(listChanged: true))
        #expect(try roundTrip(server) == server)
    }

    @Test("Initialize round-trips")
    func initialize() throws {
        let request = InitializeRequest(
            protocolVersion: "2025-11-25",
            capabilities: ClientCapabilities(roots: RootsCapability(listChanged: true)),
            clientInfo: Implementation(name: "c", version: "1"))
        #expect(try roundTrip(request) == request)

        let result = InitializeResult(
            protocolVersion: "2025-11-25",
            capabilities: ServerCapabilities(tools: ToolsCapability()),
            serverInfo: Implementation(name: "s", version: "1"),
            instructions: "be helpful")
        #expect(try roundTrip(result) == result)
    }

    @Test("Tool round-trips")
    func tool() throws {
        let tool = Tool(
            name: "add",
            title: "Add",
            description: "adds",
            inputSchema: ["type": "object"],
            outputSchema: ["type": "object"],
            annotations: ToolAnnotations(readOnlyHint: true, idempotentHint: true),
            meta: ["custom": .string("kept")])
        #expect(try roundTrip(tool) == tool)
    }

    @Test("Content round-trips across every case")
    func content() throws {
        let values: [Content] = [
            .text("hello"),
            .image(data: "aGVsbG8=", mimeType: "image/png"),
            .audio(data: "aGVsbG8=", mimeType: "audio/wav"),
            .resource(ResourceContents(uri: "file:///tmp/x.txt", text: "contents")),
            .resourceLink(
                ResourceLink(uri: "file:///tmp/x.txt", name: "x", mimeType: "text/plain", size: 8)),
        ]
        for (index, value) in values.enumerated() {
            let decoded = try roundTrip(value)
            #expect(decoded == value, "content case \(index) failed to round-trip")
        }
    }

    @Test("Unknown content kind survives round-trip verbatim")
    func unknownContent() throws {
        let raw = try jsonObject(
            """
            {"type": "future-kind", "text": "kept", "extra": {"nested": true}}
            """)
        let content = try JSONDecoder().decode(Content.self, from: try JSONEncoder().encode(raw))
        guard case .unknown(let preserved) = content else {
            Issue.record("expected unknown content kind to be preserved")
            return
        }
        #expect(preserved == raw)
        // And it re-encodes losslessly.
        #expect(try roundTrip(content) == content)
    }

    @Test("CallToolResult combines text content")
    func callToolResult() throws {
        let result = CallToolResult(
            content: [.text("line 1"), .image(data: "AAAA", mimeType: "image/png"), .text("line 2")],
            structuredContent: ["sum": .number(42)],
            isError: true)
        let decoded = try roundTrip(result)
        #expect(decoded == result)
        #expect(decoded.combinedText == "line 1\nline 2")
    }

    @Test("Resource round-trips")
    func resource() throws {
        let resource = Resource(
            uri: "file:///notes.txt", name: "notes", title: "Notes",
            description: "scratch notes", mimeType: "text/plain", size: 12)
        #expect(try roundTrip(resource) == resource)

        let template = ResourceTemplate(
            uriTemplate: "file:///{path}", name: "by-path", mimeType: "text/plain")
        #expect(try roundTrip(template) == template)

        let contents = ResourceContents(uri: "file:///bin", mimeType: "application/octet-stream", blob: "QUJD")
        #expect(try roundTrip(contents) == contents)
    }

    @Test("Prompt round-trips")
    func prompt() throws {
        let prompt = Prompt(
            name: "greet", title: "Greet", description: "greets",
            arguments: [PromptArgument(name: "who", description: "whom to greet", required: true)])
        #expect(try roundTrip(prompt) == prompt)

        let result = GetPromptResult(
            description: "a chat",
            messages: [
                PromptMessage(role: .user, content: .text("hi")),
                PromptMessage(role: .assistant, content: .text("hello")),
            ])
        #expect(try roundTrip(result) == result)
    }

    @Test("Progress token round-trips as string and number")
    func progressToken() throws {
        #expect(try roundTrip(ProgressToken.string("tok")) == .string("tok"))
        #expect(try roundTrip(ProgressToken.number(7)) == .number(7))
        #expect(try roundTrip(RequestMeta(progressToken: "p1")) == RequestMeta(progressToken: "p1"))
    }

    @Test("ProgressNotification round-trips")
    func progressNotification() throws {
        let notification = ProgressNotification(
            progressToken: "p1", progress: 0.5, total: 1, message: "halfway")
        #expect(try roundTrip(notification) == notification)
    }

    @Test("Completion round-trips")
    func completion() throws {
        let request = CompleteRequest(
            ref: .prompt("greet"), argument: CompleteArgument(name: "who", value: "al"))
        #expect(try roundTrip(request) == request)

        let resourceRef = CompleteRequest(
            ref: .resource("file:///docs"), argument: CompleteArgument(name: "path", value: "a"))
        #expect(try roundTrip(resourceRef) == resourceRef)

        let result = CompleteResult(values: ["alice", "al"], total: 2, hasMore: false)
        #expect(try roundTrip(result) == result)
    }

    @Test("Logging round-trips")
    func logging() throws {
        let notification = LogMessageNotification(
            level: .warning, logger: "db", data: ["rows": .number(3)])
        #expect(try roundTrip(notification) == notification)
        #expect(try roundTrip(SetLevelRequest(level: .notice)) == SetLevelRequest(level: .notice))
    }

    @Test("Sampling and elicitation round-trip")
    func samplingAndElicitation() throws {
        let sampling = CreateMessageRequest(
            messages: [SamplingMessage(role: .user, content: .text("hi"))],
            systemPrompt: "be brief",
            includeContext: .thisServer,
            maxTokens: 100,
            temperature: 0.2,
            stopSequences: ["\n"])
        #expect(try roundTrip(sampling) == sampling)

        let samplingResult = CreateMessageResult(
            role: .assistant, content: .text("hello"), model: "acme-1", stopReason: "endTurn")
        #expect(try roundTrip(samplingResult) == samplingResult)

        let elicit = ElicitRequest(
            message: "Pick one", requestedSchema: ["type": "object"])
        #expect(try roundTrip(elicit) == elicit)

        let elicitResult = ElicitResult(
            action: .accept, content: .text("chosen"))
        #expect(try roundTrip(elicitResult) == elicitResult)
    }

    @Test("Roots round-trip")
    func roots() throws {
        let result = ListRootsResult(roots: [Root(uri: "file:///work", name: "work")])
        #expect(try roundTrip(result) == result)
    }
}

// MARK: - Wire decoding

/// Decoding of documented wire shapes, including MCP-spec defaults for omitted
/// flag fields and lenient optional collections.
struct ModelWireDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("ToolAnnotations defaults match the MCP schema")
    func toolAnnotationDefaults() throws {
        let annotations = try decode(ToolAnnotations.self, "{}")
        #expect(!annotations.readOnlyHint)
        #expect(annotations.destructiveHint)
        #expect(!annotations.idempotentHint)
        #expect(annotations.openWorldHint)

        let explicit = try decode(
            ToolAnnotations.self,
            """
            {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
            """)
        #expect(explicit.readOnlyHint)
        #expect(!explicit.destructiveHint)
        #expect(explicit.idempotentHint)
        #expect(!explicit.openWorldHint)
    }

    @Test("List results default to empty collections")
    func listResultDefaults() throws {
        #expect(try decode(ListToolsResult.self, "{}").tools.isEmpty)
        #expect(try decode(ListResourcesResult.self, "{}").resources.isEmpty)
        #expect(try decode(ListPromptsResult.self, "{}").prompts.isEmpty)
        #expect(try decode(ListResourceTemplatesResult.self, "{}").resourceTemplates.isEmpty)
        #expect(try decode(CompleteResult.self, "{}").values.isEmpty)
        #expect(try decode(ReadResourceResult.self, "{}").contents.isEmpty)
    }

    @Test("CallToolResult defaults isError to false")
    func callToolResultDefault() throws {
        let result = try decode(CallToolResult.self, """
            {"content": [{"type": "text", "text": "ok"}]}
            """)
        #expect(!result.isError)
        #expect(result.content == [.text("ok")])
    }

    @Test("ProgressToken decodes from string or number wire form")
    func progressTokenDecoding() throws {
        struct Wrapper: Codable, Equatable {
            var token: ProgressToken
        }
        #expect(try decode(Wrapper.self, #"{"token": "abc"}"#).token == .string("abc"))
        #expect(try decode(Wrapper.self, #"{"token": 12}"#).token == .number(12))
    }

    @Test("Tool inputSchema defaults to empty object")
    func toolDefaultSchema() throws {
        let tool = try decode(Tool.self, #"{"name": "bare"}"#)
        #expect(tool.inputSchema == .object([:]))
    }

    @Test("ElicitAction decodes from all wire values")
    func elicitationAction() throws {
        #expect(try decode(ElicitAction.self, #""accept""#) == .accept)
        #expect(try decode(ElicitAction.self, #""decline""#) == .decline)
        #expect(try decode(ElicitAction.self, #""cancel""#) == .cancel)
    }
}
