# AGENTS.md

## Commands

```sh
swift build
swift test
swift run MCPEchoServer            # example stdio server (speaks MCP on stdin/stdout)
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target MCPKit \
  --output-path ./docs \
  --transform-for-static-hosting \
  --hosting-base-path MCPKit
```

## Structure

- `Sources/MCPKit/Models/`: wire types, all `Codable` with `_meta` passthrough and MCP-schema defaults for omitted flag fields (e.g. `readOnlyHint`). Method-name strings live in `Client/` + `Server/`, not here.
- `Sources/MCPKit/Client/`: `ClientDelegate` protocol (defaults: `ping`/`roots/list` answered with empty results, sampling/elicitation throw `methodNotSupported`, notification hooks are no-ops), `Client` actor (`connect()` = `initialize` + `notifications/initialized`; capability-gated outgoing calls; progress-token routing to `callTool`/`readResource`/`getPrompt` `onProgress` closures).
- `Sources/MCPKit/Server/`: `ServerDelegate` protocol (required: `capabilities`, `info`; handlers default to `methodNotSupported`), `Server` actor (registers JSON-RPC handlers **only** for advertised capabilities; `-32002` for requests before `initialize`; echo-if-known version negotiation), `ServerContext` (per-request progress token + `reportProgress`), `DrainingTransport` (wraps the transport so `run()` does not report termination until requests received before EOF are answered; 30s drain timeout).
- `Sources/MCPEchoServer/`: example server + subprocess test fixture. stdout is protocol-only; it bootstraps swift-log to stderr.

## Conventions

- Swift 6 strict concurrency; `swift-tools-version: 6.3` with `ApproachableConcurrency` enabled. Actors for `Client`/`Server`; `Synchronization.Mutex` (not `NSLock`) for shared mutable state.
- JSON-RPC comes from the external JSONRPCKit dependency (`JSONRPCPeer`, `Transport`, `StdioTransport`, `ProcessTransport`, `JSONValue`). Do not add JSON-RPC sources to this package; improve JSONRPCKit upstream instead.
- Protocol version constants live in `Models/Protocol.swift` (`latestMCPProtocolVersion = "2025-11-25"`, `knownMCPProtocolVersions`). Negotiation: server echoes a known requested version or responds with latest; client rejects unknown versions from the server with `MCPError.unsupportedProtocolVersion`.
- Default `Logger`s write to stderr (`StreamLogHandler.standardError`) because stdout may be a protocol channel.
- `Server.run()` is cancellation-aware (cancellation = shutdown) and self-retains from `start()` until termination, so a started server keeps serving even if the caller drops its reference.
- Capability gating belongs in `Client`/`Server`, not in delegate implementations.
- `MCPError` conforms to `JSONRPCErrorConvertible`: `-32601` methodNotSupported, `-32602` invalidParams, `-32002` serverNotInitialized; other thrown errors surface as `-32603` internal.
- Tests are table-driven (Swift Testing): one `@Test("name", arguments: [cases])` per behavior group with a `Sendable` case struct (`name` field for failure identification, expected-value field, single assertion path). Add new cases as rows, not new funcs. Shared fakes live in `Tests/MCPKitTests/TestTransports.swift` (`CapturingTransport`, `AutoRespondingTransport` with a `sideEffect` hook, loopback pair). `EndToEndTests.swift` covers loopback client↔server pairs and a real `MCPEchoServer` subprocess (guarded on the built binary's existence).
- The MCPEchoServer binary is at `.build/out/Products/Debug/MCPEchoServer` with this toolchain (Xcode-style build layout); the test locator also checks `.build/debug/` for other toolchains.
