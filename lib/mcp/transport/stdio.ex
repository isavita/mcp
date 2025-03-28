defmodule MCP.Transport.Stdio do
  @moduledoc """
  Implementation of the MCP transport behavior using Elixir Ports.

  This module manages communication with an external MCP server process
  launched via a specified command. It uses Elixir's `Port` mechanism
  to interact with the external process's stdin and stdout.
  """

  use GenServer
  require Logger
  alias MCP.Protocol.{Parser, Formatter}

  @behaviour MCP.Transport.Behaviour

  # Client API (Transport Behaviour Implementation)

  @impl MCP.Transport.Behaviour
  @doc """
  Starts a new STDIO transport process that manages an external server.

  ## Options
    * `:command` (required) - A string containing the command and arguments to launch the external MCP server (e.g., `"npx -y @modelcontextprotocol/server-filesystem /path/to/data"`).
    * `:debug_mode` - Enable debug logging (default: Application.get_env(:mcp, :debug, false)).
    * `:name` - Name for the process registration.
    * `:port_options` - Additional options for `Port.open/2` (default: `[:binary, {:packet, :line}, :exit_status, :hide, env: System.get_env()]`).
  """
  def start_link(opts \\ []) do
    unless Keyword.has_key?(opts, :command) do
      raise ArgumentError, ":command option is required for MCP.Transport.Stdio"
    end

    {name_opt, transport_opts} = Keyword.pop(opts, :name)
    gen_opts = if name_opt, do: [name: name_opt], else: []

    GenServer.start_link(__MODULE__, transport_opts, gen_opts)
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Sends a message through the STDIO transport to the external process's stdin.
  The message will be encoded as JSON with a newline.
  """
  def send_message(pid, message) do
    GenServer.call(pid, {:send, message})
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Registers a process to receive incoming messages from the external process's stdout.

  The registered process will receive messages in the format:
  `{:mcp_message, message}`

  If the handler process dies, it will be automatically unregistered.
  """
  def register_handler(pid, handler_pid) when is_pid(handler_pid) do
    GenServer.call(pid, {:register_handler, handler_pid})
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Closes the STDIO transport, terminating the GenServer and closing the port
  to the external process.
  """
  def close(pid) do
    try do
      GenServer.stop(pid, :normal)
    catch
      # Process already terminated, that's fine
      :exit, _ -> :ok
    end
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Returns the current state of the transport for debugging.
  """
  def get_state(pid) do
    try do
      GenServer.call(pid, :get_state)
    catch
      :exit, _ -> {:error, :process_not_available}
    end
  end

  # GenServer Implementation

  @impl GenServer
  def init(opts) do
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))
    command = Keyword.fetch!(opts, :command)

    default_port_opts = [
      # Work with binary data
      :binary,
      # Read line by line (MCP uses newline-delimited JSON)
      {:packet, :line},
      # Get notification when the external process exits
      :exit_status,
      # Hide window on OSes that might show one
      :hide,
      # Pass environment variables
      env: System.get_env()
    ]

    port_opts = Keyword.get(opts, :port_options, default_port_opts)

    if debug_mode do
      Logger.debug("Starting STDIO transport with command: #{inspect(command)}")
      Logger.debug("Port options: #{inspect(port_opts)}")
    end

    # Set up trap_exit to handle termination gracefully
    Process.flag(:trap_exit, true)

    try do
      port = Port.open({:spawn, command}, port_opts)

      if debug_mode do
        Logger.debug("Port opened successfully: #{inspect(port)}")
      end

      {:ok,
       %{
         debug_mode: debug_mode,
         command: command,
         port: port,
         handler: nil,
         handler_ref: nil
         # No buffer needed due to {:packet, :line}
       }}
    catch
      kind, reason ->
        Logger.error(
          "Failed to open port for command '#{command}'. Reason: #{kind} - #{inspect(reason)}"
        )

        {:stop, {:port_open_failed, {kind, reason}}}
    end
  end

  @impl GenServer
  def handle_call({:register_handler, handler_pid}, _from, state) do
    # Remove existing handler monitoring if present
    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end

    # Set up monitoring for the new handler
    ref = Process.monitor(handler_pid)

    if state.debug_mode do
      Logger.debug("STDIO transport registered new handler: #{inspect(handler_pid)}")
    end

    {:reply, :ok, %{state | handler: handler_pid, handler_ref: ref}}
  end

  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    if state.debug_mode do
      Logger.debug("STDIO transport sending to port: #{inspect(message)}")
    end

    result =
      try do
        # encode adds the newline
        encoded = Formatter.encode(message)

        if Port.command(state.port, encoded) do
          :ok
        else
          # This usually means the port is closed or closing
          Logger.error("Port.command failed, port may be closed.")
          {:error, :port_command_failed}
        end
      rescue
        e ->
          Logger.error("Error encoding message: #{inspect(e)}")
          {:error, {:encode_failed, e}}
      catch
        :exit, reason ->
          Logger.error("Error sending message via Port.command: #{inspect(reason)}")
          {:error, {:port_command_crashed, reason}}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    # Don't expose monitor references or the raw port in the returned state
    safe_state = Map.drop(state, [:port, :handler_ref])
    {:reply, {:ok, safe_state}, state}
  end

  @impl GenServer
  def handle_call(:get_raw_port_for_test, _from, state) do
    # ONLY FOR TESTING - allows checking Port.info
    {:reply, state.port, state}
  end

  # Handle messages FROM the external process via the Port
  @impl GenServer
  def handle_info({port, {:data, {:packet, :line, line}}}, %{port: port} = state) do
    # Received a line from the external process's stdout
    if state.debug_mode do
      Logger.debug("STDIO transport received line from port: #{inspect(line)}")
    end

    case Parser.parse(line) do
      {:ok, message} ->
        if state.handler do
          send(state.handler, {:mcp_message, message})
        else
          Logger.warning(
            "No handler registered for STDIO transport, dropping message: #{inspect(message)}"
          )
        end

      {:error, reason} ->
        Logger.error(
          "Error parsing message from port: #{inspect(reason)}. Line: #{inspect(line)}"
        )
    end

    {:noreply, state}
  end

  # Handle port closure/exit
  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # The external process terminated
    Logger.error("External process for STDIO transport exited with status: #{status}")
    {:stop, {:external_process_exited, status}, state}
  end

  # Handle linked handler process exit
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{handler_ref: ref, handler: pid} = state) do
    Logger.info("STDIO handler process down: #{inspect(reason)}, unregistering")
    {:noreply, %{state | handler: nil, handler_ref: nil}}
  end

  # Catch-all for other messages
  @impl GenServer
  def handle_info(message, state) do
    if state.debug_mode do
      Logger.debug("STDIO transport received unexpected message: #{inspect(message)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("STDIO transport terminating: #{inspect(reason)}")

    # Clean up resources
    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end

    # Close the port if it's still open
    if state.port && Port.info(state.port) do
      # Maybe send SIGTERM/SIGKILL? For now, just close.
      Port.close(state.port)
      Logger.info("Closed port to external process.")
    end

    :ok
  end
end
