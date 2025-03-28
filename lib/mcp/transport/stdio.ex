defmodule MCP.Transport.Stdio do
  @moduledoc """
  Implementation of the MCP transport behavior using Elixir Ports.

  This module manages communication with an external MCP server process
  launched via a specified command. It uses Elixir's `Port` mechanism
  to interact with the external process's stdin and stdout.
  It handles manual message framing based on newlines.
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
    * `:port_options` - Additional options for `Port.open/2` (default: `[:binary, :exit_status, :hide, env: System.get_env()]`). Note: `{:packet, :line}` is intentionally omitted due to potential :badarg issues.
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
  def send_message(pid, message) do
    GenServer.call(pid, {:send, message})
  end

  @impl MCP.Transport.Behaviour
  def register_handler(pid, handler_pid) when is_pid(handler_pid) do
    GenServer.call(pid, {:register_handler, handler_pid})
  end

  @impl MCP.Transport.Behaviour
  def close(pid) do
    try do
      GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end
  end

  @impl MCP.Transport.Behaviour
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

    # Manual line buffering is now required.
    default_port_opts = [
      :binary, # Work with binary data
      :exit_status, # Get notification when the external process exits
      :hide, # Hide window on OSes that might show one
    ]

    port_opts = Keyword.get(opts, :port_options, default_port_opts)

    if debug_mode do
      Logger.debug("Starting STDIO transport with command: #{inspect(command)}")
      Logger.debug("Port options (manual line handling): #{inspect(port_opts)}")
    end

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
         handler_ref: nil,
         buffer: "" # ADDED: Buffer for manual line processing
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
    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end
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
        # Ensure message is encoded WITH newline for line-based external processes
        encoded = Formatter.encode(message) # encode adds the newline

        if Port.command(state.port, encoded) do
          :ok
        else
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
    safe_state = Map.drop(state, [:port, :handler_ref])
    {:reply, {:ok, safe_state}, state}
  end

  @impl GenServer
  def handle_call(:get_raw_port_for_test, _from, state) do
    {:reply, state.port, state}
  end

  # Handle RAW data FROM the external process via the Port
  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    # Received a chunk of data from the external process's stdout
    if state.debug_mode do
      Logger.debug("STDIO transport received raw data from port: #{byte_size(data)} bytes")
      # Uncomment to see data, but can be noisy:
      # Logger.debug("Data: #{inspect(data)}")
    end

    # Append data to buffer and process lines
    new_buffer = state.buffer <> data
    process_buffer(new_buffer, state) # Returns {:noreply, new_state}
  end

  # Handle port closure/exit
  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("External process for STDIO transport exited with status: #{status}")
    # Process any remaining data in the buffer before stopping
    {:noreply, final_state} = process_buffer(state.buffer <> "\n", state) # Add newline to flush
    {:stop, {:external_process_exited, status}, final_state}
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
    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end
    if is_port(state.port) && Port.info(state.port) != nil do
      Port.close(state.port)
      Logger.info("Closed port to external process.")
    end
    :ok
  end

  # --- Private Helper Functions ---

  # ADDED: Process buffer to extract and handle complete lines/messages
  defp process_buffer(buffer, state) do
    case Parser.extract_message(buffer) do
      # Found a complete message
      {:ok, message, rest} ->
        if state.debug_mode do
          Logger.debug("STDIO transport parsed message: #{inspect(message)}")
        end
        # Process the message
        if state.handler do
          send(state.handler, {:mcp_message, message})
        else
          Logger.warning("No handler registered for STDIO transport, dropping message")
        end
        # Continue processing rest of buffer recursively
        process_buffer(rest, state)

      # Buffer doesn't contain a complete message yet
      {:incomplete, incomplete_buffer} ->
        # Need more data, update buffer and wait
        {:noreply, %{state | buffer: incomplete_buffer}}

      # Found invalid JSON or non-message line
      {:error, reason, rest} ->
        Logger.error("Error parsing message from port buffer: #{inspect(reason)}")
        # Skip the invalid message and continue with the rest
        process_buffer(rest, state)
    end
  end
end
