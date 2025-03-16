# MCP

[![Hex.pm](https://img.shields.io/hexpm/v/mcp.svg)](https://hex.pm/packages/mcp)
[![Hexdocs.pm](https://img.shields.io/badge/api-docs-purple.svg)](https://hexdocs.pm/mcp)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An Elixir client library for the [Model Context Protocol (MCP)](https://github.com/model-context-protocol), which enables communication between LLMs and external tools, data sources, and services.

## Features

- **Standard-Compliant**: Full implementation of the JSON-RPC 2.0 based MCP specification
- **Transport Agnostic**: Designed for extensibility with pluggable transports (currently supports stdio)
- **Type Safe**: Properly typed API for all MCP operations
- **Well Tested**: Comprehensive test suite ensures reliability
- **Documented**: Complete documentation with examples
- **Performant**: Low overhead, designed for efficient communication

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

### Basic Client

```elixir
# Start a client
{:ok, client} = MCP.start_client()

# Initialize the connection
{:ok, capabilities} = MCP.Client.initialize(client)

# Send initialized notification
:ok = MCP.Client.send_initialized(client)

# List available resources
{:ok, resources} = MCP.Client.list_resources(client)

# Read a specific resource
{:ok, content} = MCP.Client.read_resource(client, "file:///path/to/resource")
```

### Debugging

To enable debug logging:

```elixir
# Enable debug mode for all new clients
MCP.enable_debug()

# Or start a specific client with debug mode
{:ok, client} = MCP.start_client(debug_mode: true)
```

### Advanced Configuration

For more complex scenarios, you can configure the client directly:

```elixir
{:ok, client} = MCP.Client.start_link([
  debug_mode: true,
  transport: MCP.Transport.Stdio,
  transport_opts: [
    name: MyApp.MCPTransport
  ]
])
```

## Architecture

The MCP library is designed with a modular architecture:

- **MCP**: Top-level module providing configuration and convenience functions
- **MCP.Client**: Manages communication with an MCP server
- **MCP.Transport.Behaviour**: Defines the interface for transport implementations
- **MCP.Transport.Stdio**: Implementation of the transport behavior for stdin/stdout
- **MCP.Protocol**: Contains protocol-specific modules:
  - **MCP.Protocol.Formatter**: Creates properly formatted MCP messages
  - **MCP.Protocol.Parser**: Parses raw input into MCP messages
  - **MCP.Protocol.Validator**: Validates message structure

This design allows for easy extension with new transport types (e.g., HTTP, TCP) while maintaining the same client interface.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- The [Model Context Protocol](https://github.com/model-context-protocol) team for the specification
- All contributors who have helped build and improve this library
```

This provides a solid foundation for your MCP library. The MCP module offers a simple public API with convenience functions, while the README.md provides comprehensive documentation that explains the library's purpose, how to use it, and its architecture.

The README includes badges, installation instructions, usage examples, architectural overview, and contribution guidelines, making it easy for users to understand and start using the library.

Would you like me to make any changes or additions to either the MCP module or the README.md?
