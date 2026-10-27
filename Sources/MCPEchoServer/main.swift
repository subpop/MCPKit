// MCPEchoServer: a minimal MCP stdio server, used as an example and as MCPKit's
// subprocess test fixture.
//
// stdout carries JSON-RPC message framing exclusively; bootstrap swift-log to stderr
// so diagnostics never corrupt the protocol channel.
import Foundation
import JSONRPCKit
import Logging
import MCPKit

LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }

struct EchoServer: ServerDelegate {
    let capabilities = ServerCapabilities(
        logging: LoggingCapability(),
        tools: ToolsCapability(listChanged: true))

    let info = Implementation(name: "MCPEchoServer", version: "1.0.0")

    func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult {
        ListToolsResult(tools: [
            Tool(
                name: "echo",
                description: "Echoes the 'text' argument back as text content.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Text to echo"],
                    ],
                    "required": ["text"],
                ]),
            Tool(
                name: "add",
                description: "Adds two integers; returns the sum as structured output.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "a": ["type": "integer"],
                        "b": ["type": "integer"],
                    ],
                    "required": ["a", "b"],
                ],
                outputSchema: [
                    "type": "object",
                    "properties": ["sum": ["type": "integer"]],
                    "required": ["sum"],
                ]),
        ])
    }

    func callTool(_ request: CallToolRequest, context: ServerContext) async throws
        -> CallToolResult
    {
        switch request.name {
        case "echo":
            let text = request.arguments?["text"]?.stringValue ?? ""
            // Report progress only when the client attached a progress token.
            try await context.reportProgress(0.5, message: "halfway")
            return CallToolResult(content: [.text(text)])
        case "add":
            struct AddArguments: Decodable {
                var a: Double
                var b: Double
            }
            let arguments = try JSONValue(encoding: request.arguments ?? [:])
                .decode(as: AddArguments.self)
            let sum = Int(arguments.a + arguments.b)
            return CallToolResult(
                content: [.text("\(sum)")],
                structuredContent: ["sum": .number(Double(sum))])
        default:
            throw MCPError.invalidParams("unknown tool: \(request.name)")
        }
    }

    func setLogLevel(_ request: SetLevelRequest) async {}
}

let server = Server(delegate: EchoServer())
try await server.run()
