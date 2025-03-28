# MCP

[![Hex.pm](https://img.shields.io/hexpm/v/mcp.svg)](https://hex.pm/packages/mcp)
[![Hexdocs.pm](https://img.shields.io/badge/api-docs-purple.svg)](https://hexdocs.pm/mcp)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

An Elixir client library for the [Model Context Protocol (MCP)](https://github.com/model-context-protocol), enabling communication between LLMs and external tools, data sources, and services.

## Features

- **Standard-Compliant**: Full implementation of the JSON-RPC 2.0 based MCP specification
- **Transport Agnostic**: Extensible with pluggable transports (currently supports stdio)
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

### Basic Client with Filesystem Server

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
- **MCP.Protocol**: Protocol-specific modules (Formatter, Parser, Validator)

This design allows for easy extension with new transport types while maintaining a consistent client interface.

## License

Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- The [Model Context Protocol](https://github.com/model-context-protocol) team
- All contributors to this library
