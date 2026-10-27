# Contributing

## Workflow

1. Sync types against the canonical schema before changing `Sources/MCPKit/Models/`: the MCP TypeScript schema at `https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts` (or the JSON Schema from the corresponding spec release) is the source of truth. Keep field defaults (e.g. `readOnlyHint: false`, `destructiveHint: true`) aligned with the schema's documented defaults.
2. Keep `ServerDelegate`/`ClientDelegate` defaults as `methodNotSupported` (or no-op for notifications); register a handler only together with its typed model and the capability that gates it.
3. Add/extend tests under `Tests/MCPKitTests/` (Swift Testing, `#expect`). Follow the table-driven pattern: one `@Test("behavior", arguments: [cases])` per behavior with a `Sendable` case struct (see `ServerTests.swift` and `TestTransports.swift` for the shared `CapturingTransport` / `AutoRespondingTransport` fakes). Add coverage as new rows, not new test funcs.
4. Run `swift build` and `swift test` before opening a PR.

## DocC

Document public types/methods with `///` comments. Docs publish automatically via `.github/workflows/docs.yml` on push to `main` (see `README.md` for the local preview command). Requires enabling GitHub Pages (source: GitHub Actions) once per repo.

## Protocol version bumps

`latestMCPProtocolVersion` and `knownMCPProtocolVersions` are centralized in `Sources/MCPKit/Models/Protocol.swift`. When a new MCP revision is ratified: add it to the known set, flip `latestMCPProtocolVersion`, extend models for new fields (leniently — preserve unknowns where possible), and add schema round-trip rows to `ModelsCodableTests.swift`.

## Known gaps (good first issues)

- `notifications/cancelled` (cooperative cancellation of in-flight requests).
- JSON-RPC batching (MCP 2025-06-18 removed it; revisit only if the spec reinstates it).
- Forward-compat: preserve unknown content-block `type` variants is done via `Content.unknown`; extend the same pattern if new discriminated unions appear.
- A loopback conformance harness that replays the official MCP schema fixtures.
