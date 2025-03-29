# MCP

[![Hex.pm](https://img.shields.io/hexpm/v/mcp.svg)](https://hex.pm/packages/mcp)
[![Hexdocs.pm](https://img.shields.io/badge/api-docs-purple.svg)](https://hexdocs.pm/mcp)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

An Elixir client library for the [Model Context Protocol (MCP)](https://github.com/model-context-protocol), enabling communication between LLMs and external tools, data sources, and services.

## Features

- **Standard-Compliant**: Full implementation of the JSON-RPC 2.0 based MCP specification
- **Transport Agnostic**: Extensible with pluggable transports (supports stdio and SSE)
- **Tool Integration**: Seamless access to filesystem operations, prompts, and more

## Installation

Add `mcp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mcp, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Client with Filesystem Server (STDIO Transport)

```elixir
# Start a client with filesystem MCP server
{:ok, client} = MCP.Client.start_link([
  transport: MCP.Transport.Stdio,
  transport_opts: [
    command: "npx -y @modelcontextprotocol/server-filesystem /path/to/directory"
  ]
])

# Initialize the connection
{:ok, capabilities} = MCP.Client.initialize(client)
:ok = MCP.Client.send_initialized(client)

# List available tools
{:ok, tools} = MCP.Client.list_tools(client)

# Call a tool - list directory contents
{:ok, result} = MCP.Client.call_tool(client, "list_directory", 
  arguments: %{"path" => "/path/to/directory"})

# Clean up when done
MCP.Client.close(client)
```

### Server-Sent Events (SSE) Transport

The library also provides an SSE transport for real-time communication over HTTP:

```elixir
# Start a client with SSE transport
{:ok, client} = MCP.Client.start_link([
  transport: MCP.Transport.SSE,
  transport_opts: [
    port: 4000,           # Port to listen on (default: 4000)
    path: "/mcp"          # Path to listen on (default: "/mcp")
  ]
])

# Initialize the connection
{:ok, capabilities} = MCP.Client.initialize(client)
:ok = MCP.Client.send_initialized(client)

# Now the client is available via SSE at http://localhost:4000/mcp
```

#### Connecting to an SSE MCP Server

To receive SSE events from the MCP server, connect with a GET request:

```
GET /mcp HTTP/1.1
Accept: text/event-stream
```

To send data to the MCP server, make a POST request to the SSE endpoint:

```
POST /mcp HTTP/1.1
Content-Type: application/json

{"jsonrpc":"2.0","method":"test_method","params":{"param":"value"},"id":"req-1"}
```

### Debugging

```elixir
# Enable debug mode for all new clients
MCP.enable_debug()

# Or start a specific client with debug mode
{:ok, client} = MCP.start_client(debug_mode: true, 
  transport_opts: [command: "npx -y @modelcontextprotocol/server-filesystem /path/to/directory"])
```

## Architecture

The MCP library uses a modular architecture:

- **MCP**: Top-level configuration and convenience functions
- **MCP.Client**: Communication management with MCP servers
- **MCP.Transport.Behaviour**: Interface for transport implementations
- **MCP.Transport.Stdio**: Stdin/stdout transport implementation
- **MCP.Transport.SSE**: Server-Sent Events transport implementation
- **MCP.Protocol**: Protocol-specific modules (Formatter, Parser, Validator)

This design allows for easy extension with new transport types while maintaining a consistent client interface.

## License

Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- The [Model Context Protocol](https://github.com/model-context-protocol) team
- All contributors to this library
