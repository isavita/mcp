defmodule MCP.Transport.Stdio do
  @moduledoc """
  Implementation of the MCP transport behavior for stdin/stdout communication.

  This module manages bidirectional communication over standard input/output streams,
  which is particularly useful for communicating with parent processes or when running
  as a subprocess of an editor or other tool.
  """

  use GenServer
  require Logger
  alias MCP.Protocol.{Parser, Formatter}

  @behaviour MCP.Transport.Behaviour

  # Client API (Transport Behaviour Implementation)

  @impl MCP.Transport.Behaviour
  @doc """
  Starts a new STDIO transport process.

  ## Options
    * `:debug_mode` - Enable debug logging (default: Application.get_env(:mcp, :debug, false))
    * `:name` - Name for the process registration
    * `:io_module` - Module to use for IO operations (default: IO)
  """
  def start_link(opts \\ []) do
    {name_opt, transport_opts} = Keyword.pop(opts, :name)

    gen_opts = if name_opt, do: [name: name_opt], else: []

    GenServer.start_link(__MODULE__, transport_opts, gen_opts)
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Sends a message through the STDIO transport.
  The message will be encoded as JSON and written to stdout.
  """
  def send_message(pid, message) do
    GenServer.call(pid, {:send, message})
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Registers a process to receive incoming messages.

  The registered process will receive messages in the format:
  `{:mcp_message, message}`

  If the process dies, it will be automatically unregistered.
  """
  def register_handler(pid, handler_pid) when is_pid(handler_pid) do
    GenServer.call(pid, {:register_handler, handler_pid})
  end

  @impl MCP.Transport.Behaviour
  @doc """
  Closes the STDIO transport, terminating the process.
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

  @doc """
  Simulates receiving data from stdin (for testing)
  """
  def simulate_input(pid, data) do
    try do
      GenServer.cast(pid, {:simulate_input, data})
    catch
      :exit, _ -> {:error, :process_not_available}
    end
  end

  # GenServer Implementation

  @impl GenServer
  def init(opts) do
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))
    io_module = Keyword.get(opts, :io_module, IO)

    if debug_mode do
      Logger.debug("Starting STDIO transport")
    end

    # If using MockIO, register with it
    if io_module == MCP.Test.MockIO do
      :ok = io_module.register_transport(self())
    end

    # Start IO reading process if not in test mode
    reader_pid =
      if io_module == IO do
        {:ok, pid} = start_reader(self(), io_module)
        pid
      else
        nil
      end

    # Set up trap_exit to handle termination gracefully
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       debug_mode: debug_mode,
       io_module: io_module,
       handler: nil,
       handler_ref: nil,
       reader: reader_pid,
       reader_ref: if(reader_pid, do: Process.monitor(reader_pid), else: nil),
       buffer: ""
     }}
  end

  @impl GenServer
  def handle_call({:register_handler, handler_pid}, _from, state) do
    # Remove existing handler monitoring if present
    if state.handler_ref do
      Process.demonitor(state.handler_ref)
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
      Logger.debug("STDIO transport sending: #{inspect(message)}")
    end

    result =
      try do
        encoded = Formatter.encode(message)
        state.io_module.binwrite(:stdio, encoded)
        :ok
      rescue
        e ->
          Logger.error("Error encoding or sending message: #{inspect(e)}")
          {:error, {:send_failed, e}}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    # Don't expose monitor references in the returned state
    safe_state = Map.drop(state, [:reader_ref, :handler_ref])
    {:reply, {:ok, safe_state}, state}
  end

  @impl GenServer
  def handle_cast({:simulate_input, data}, state) do
    process_input(data, state)
  end

  @impl GenServer
  def handle_info({:io_data, data}, state) do
    process_input(data, state)
  end

  @impl GenServer
  def handle_info({:io_error, reason}, state) do
    Logger.error("STDIO transport error: #{inspect(reason)}")
    {:stop, {:io_error, reason}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{reader_ref: ref, reader: pid} = state) do
    Logger.error("STDIO reader process down: #{inspect(reason)}")
    {:stop, {:reader_down, reason}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{handler_ref: ref, handler: pid} = state) do
    Logger.info("STDIO handler process down: #{inspect(reason)}, unregistering")
    {:noreply, %{state | handler: nil, handler_ref: nil}}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("Linked process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("STDIO transport terminating: #{inspect(reason)}")

    # Clean up resources
    if state.handler_ref do
      Process.demonitor(state.handler_ref)
    end

    if state.reader_ref do
      Process.demonitor(state.reader_ref)
    end

    if state.reader && Process.alive?(state.reader) do
      Process.exit(state.reader, :shutdown)
    end

    :ok
  end

  # Private Functions

  defp start_reader(parent, io_module) do
    Task.start_link(fn -> read_loop(parent, io_module) end)
  end

  defp read_loop(parent, io_module) do
    case io_module.binread(:stdio, :line) do
      :eof ->
        send(parent, {:io_error, :eof})

      {:error, reason} ->
        send(parent, {:io_error, reason})

      data when is_binary(data) ->
        send(parent, {:io_data, data})
        read_loop(parent, io_module)
    end
  end

  defp process_input(data, state) do
    if state.debug_mode do
      Logger.debug("STDIO transport received: #{inspect(data)}")
    end

    # Add received data to buffer
    new_buffer = state.buffer <> data

    # Process messages until buffer is empty or incomplete
    process_buffer(new_buffer, state)
  end

  defp process_buffer(buffer, state) do
    case Parser.extract_message(buffer) do
      {:ok, message, rest} ->
        # Process the message
        if state.handler do
          send(state.handler, {:mcp_message, message})
        else
          Logger.warning("No handler registered for STDIO transport, dropping message")
        end

        # Continue processing rest of buffer
        process_buffer(rest, state)

      {:incomplete, incomplete_buffer} ->
        # Need more data to complete the message
        {:noreply, %{state | buffer: incomplete_buffer}}

      {:error, reason, rest} ->
        Logger.error("Error parsing message: #{inspect(reason)}")
        # Skip the invalid message and continue with the rest
        process_buffer(rest, state)
    end
  end
end
