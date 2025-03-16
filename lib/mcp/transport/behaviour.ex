defmodule MCP.Transport.Behaviour do
  @moduledoc """
  Defines the behavior that all MCP transport implementations must follow.

  This behavior ensures that all transport implementations provide a consistent
  interface for starting, stopping, and communicating through different channels.
  """

  @typedoc "Options for starting a transport"
  @type options :: keyword()

  @typedoc "A message in the MCP protocol"
  @type message :: map()

  @typedoc "Error reason"
  @type error :: term()

  @doc """
  Starts the transport with the given options.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @callback start_link(options()) :: {:ok, pid()} | {:error, error()}

  @doc """
  Sends a message through the transport.
  The implementation handles encoding and actual delivery.
  """
  @callback send_message(pid(), message()) :: :ok | {:error, error()}

  @doc """
  Registers a process to receive incoming messages.
  All received messages will be forwarded to this process.
  """
  @callback register_handler(pid(), pid()) :: :ok | {:error, error()}

  @doc """
  Closes the transport connection, cleaning up any resources.
  """
  @callback close(pid()) :: :ok | {:error, error()}

  @doc """
  Returns the current state of the transport for debugging purposes.
  """
  @callback get_state(pid()) :: {:ok, map()} | {:error, error()}
end
