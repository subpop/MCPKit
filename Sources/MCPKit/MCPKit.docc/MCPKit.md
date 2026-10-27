# MCPKit

Swift implementation of the [Model Context Protocol](https://modelcontextprotocol.io/)
(MCP, `2025-11-25`): typed models, JSON-RPC over stdio, and client/server connections.

## Overview

- **``Client``** — connect to an MCP server (spawned as a subprocess), list and call
  tools, read resources, render prompts, set log levels, and complete arguments.
  Server-initiated requests (`roots/list`, `sampling/createMessage`,
  `elicitation/create`) are served by an optional ``ClientDelegate``.
- **``Server``** — serve MCP over stdio by implementing a ``ServerDelegate``.
  Capabilities are declared up front; handlers are registered only for the
  capabilities you advertise.
- **Models** — Codable wire types with `_meta` passthrough and preservation of
  unknown content-block variants.

JSON-RPC framing and the stdio transports come from
[JSONRPCKit](https://github.com/subpop/JSONRPCKit).

## Topics

- ### Client
  - ``Client``
  - ``ClientDelegate``
- ### Server
  - ``Server``
  - ``ServerDelegate``
  - ``ServerContext``
- ### Protocol
  - ``InitializeRequest``, ``InitializeResult``
  - ``latestMCPProtocolVersion``
- ### Errors
  - ``MCPError``
