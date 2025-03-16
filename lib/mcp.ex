defmodule MCP do
  @moduledoc """
  Model Context Protocol (MCP) client implementation for Elixir.

  This library provides a client for communicating with servers that implement the Model Context Protocol,
  which is used to bridge LLMs with external tools, data sources, and services.

  ## Features

  * Communication over standard input/output (stdio)
  * Request/response correlation
  * Proper JSON-RPC 2.0 implementation
  * Support for multiple transports (extensible architecture)
  * Typed API for standard MCP operations

  ## Example Usage

  ```elixir
  # Start a client using stdio transport
  {:ok, client} = MCP.start_client()

  # Initialize the connection
  {:ok, capabilities} = MCP.Client.initialize(client)

  # List available resources
  {:ok, resources} = MCP.Client.list_resources(client)

  # Read a specific resource
  {:ok, content} = MCP.Client.read_resource(client, "file:///path/to/resource")
  ```

  For advanced configuration, see the documentation for `MCP.Client`.
  """

  @doc """
  Returns the version of the MCP library.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:mcp, :vsn) |> to_string()
  end

  @doc """
  Starts a client for communicating with an MCP server.

  This is a convenience function that starts an MCP client configured
  for stdio communication. For more advanced options, use `MCP.Client.start_link/1`
  directly.

  ## Options

  All options are passed to `MCP.Client.start_link/1`. Common options include:

  * `:debug_mode` - Enable debug logging (default: `false`)
  * `:name` - Register the client process with this name

  ## Returns

  * `{:ok, pid}` - The client was started successfully
  * `{:error, reason}` - The client could not be started

  ## Example

  ```elixir
  {:ok, client} = MCP.start_client(debug_mode: true)
  ```
  """
  @spec start_client(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(opts \\ []) do
    MCP.Client.start_link(opts)
  end

  @doc """
  Enables debug mode for the MCP library.

  This configures the library to log debug information, which is helpful
  for troubleshooting. It affects all newly started processes but does not
  change the behavior of already running processes.

  ## Example

  ```elixir
  MCP.enable_debug()
  {:ok, client} = MCP.start_client()  # Will log debug info
  ```
  """
  @spec enable_debug() :: :ok
  def enable_debug do
    Application.put_env(:mcp, :debug, true)
    :ok
  end

  @doc """
  Disables debug mode for the MCP library.

  This configures the library to log only important information, which
  reduces noise in production environments.

  ## Example

  ```elixir
  MCP.disable_debug()
  {:ok, client} = MCP.start_client()  # Will not log debug info
  ```
  """
  @spec disable_debug() :: :ok
  def disable_debug do
    Application.put_env(:mcp, :debug, false)
    :ok
  end

  @doc """
  Returns whether debug mode is currently enabled.

  ## Example

  ```elixir
  if MCP.debug_enabled?() do
    # Debug-specific operations
  end
  ```
  """
  @spec debug_enabled?() :: boolean()
  def debug_enabled? do
    Application.get_env(:mcp, :debug, false)
  end
end
