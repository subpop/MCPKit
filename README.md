# MCPKit

Swift implementation of the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP, protocol version `2025-11-25`): typed models, JSON-RPC transport, and client/server connections over stdio.

## Layout

| Path | Description |
| --- | --- |
| `Sources/MCPKit/Models/` | Codable request/response/notification types: `initialize`, tools, resources, prompts, logging, completion, roots, sampling, elicitation, progress, capabilities, `_meta` passthrough. |
| `Sources/MCPKit/Client/` | `Client` actor (drives `initialize`, `ping`, `tools/*`, `resources/*`, `prompts/*`, `logging/setLevel`, `completion/complete`; serves `roots/list`, `sampling/createMessage`, `elicitation/create` via an optional `ClientDelegate`). |
| `Sources/MCPKit/Server/` | `Server` actor (serves the client-facing surface; dispatches to a `ServerDelegate`), `ServerContext` (progress reporting), `DrainingTransport` (keeps a stdio server alive until pipelined requests are answered on EOF). |
| `Sources/MCPEchoServer/` | Minimal example stdio server; also used as the subprocess fixture in the test suite. |

JSON-RPC framing (`JSONRPCPeer`, `StdioTransport`, `ProcessTransport`, `JSONValue`) comes from [JSONRPCKit](https://github.com/subpop/JSONRPCKit).

## Usage

Implement a server (only `capabilities`, `info`, and the handlers behind advertised capabilities are required):

```swift
import MCPKit

struct MyServer: ServerDelegate {
    let capabilities = ServerCapabilities(tools: ToolsCapability())
    let info = Implementation(name: "my-server", version: "1.0.0")

    func listTools(_ request: ListToolsRequest) async throws -> ListToolsResult {
        ListToolsResult(tools: [Tool(name: "echo", description: "Echoes text")])
    }

    func callTool(_ request: CallToolRequest, context: ServerContext) async throws -> CallToolResult {
        try await context.reportProgress(0.5, message: "halfway")
        return CallToolResult(content: [.text("echo!")])
    }
}

// Serve MCP over this process's stdin/stdout.
let server = Server(delegate: MyServer())
try await server.run()   // returns at stdin EOF, after in-flight requests are answered
```

Drive a server as a client:

```swift
import MCPKit

// Spawn a stdio server as a child process…
let client = try Client(command: "/path/to/server", args: [])
// …or bring your own transport: Client(transport: someTransport)
try await client.connect()

let tools = try await client.listTools()
let result = try await client.callTool(name: "echo", arguments: ["text": "hi"]) { progress in
    print(progress.progress)  // notifications/progress updates
}
```

All other `ServerDelegate`/`ClientDelegate` methods default to `methodNotSupported` errors (or no-ops for notifications); override only what the advertised capabilities require.

### A note on logging

MCPKit's default loggers write to **stderr**. Never log to stdout in a stdio server: stdout is the protocol channel.

## Build & test

```sh
swift build
swift test
```

## Documentation

API reference is generated with Swift DocC and published to GitHub Pages by
`.github/workflows/docs.yml` on every push to `main`.

Preview locally:

```sh
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target MCPKit \
  --output-path ./docs \
  --transform-for-static-hosting \
  --hosting-base-path MCPKit
```

## Feature coverage

Implements MCP `2025-11-25` core over stdio, both directions:

- Lifecycle: `initialize` (version negotiation, `-32002` before initialize), `notifications/initialized`, `ping`.
- Tools: `tools/list` (pagination), `tools/call` (progress tokens, structured output, `isError` results), `notifications/tools/list_changed`.
- Resources: `resources/list`, `resources/templates/list`, `resources/read`, `resources/subscribe`/`unsubscribe` (capability-gated), `notifications/resources/*`.
- Prompts: `prompts/list`, `prompts/get`, `notifications/prompts/list_changed`.
- Logging: `logging/setLevel`, `notifications/message`.
- Completion: `completion/complete` (prompt and resource references).
- Server → client: `roots/list` + `notifications/roots/list_changed`, `sampling/createMessage`, `elicitation/create`.
- Progress: `_meta.progressToken` attachment and `notifications/progress` routing on both sides.

Out of scope for now (see `CONTRIBUTING.md`): HTTP/SSE transports, authorization, Tasks, MCP Apps, JSON-RPC batching, `notifications/cancelled`, multi-server management.
