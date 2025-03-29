defmodule MCP.Transport.SSE do
  @moduledoc """
  Implementation of the MCP transport behavior using Server-Sent Events (SSE).

  This module provides a transport layer that uses HTTP and Server-Sent Events (SSE)
  to communicate with an MCP client or server. It runs a Bandit HTTP server
  with a Plug that handles SSE connections.
  """

  use GenServer
  require Logger
  alias MCP.Protocol.Parser

  @behaviour MCP.Transport.Behaviour

  # Client API (Transport Behaviour Implementation)

  @impl MCP.Transport.Behaviour
  @doc """
  Starts a new SSE transport that manages SSE connections.

  ## Options
    * `:port` - The port to listen on (default: 4000)
    * `:path` - The path to listen on (default: "/mcp")
    * `:debug_mode` - Enable debug logging (default: Application.get_env(:mcp, :debug, false))
    * `:name` - Name for the process registration
  """
  def start_link(opts \\ []) do
    {name_opt, transport_opts} = Keyword.pop(opts, :name)

    if name_opt do
      GenServer.start_link(__MODULE__, transport_opts, name: name_opt)
    else
      GenServer.start_link(__MODULE__, transport_opts)
    end
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
    GenServer.stop(pid, :normal)
  end

  @impl MCP.Transport.Behaviour
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # GenServer Implementation

  @impl GenServer
  def init(opts) do
    port = Keyword.get(opts, :port, 4000)
    path = Keyword.get(opts, :path, "/mcp")
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))

    if debug_mode do
      Logger.debug("Starting SSE transport on port #{port}, path #{path}")
    end

    Process.flag(:trap_exit, true)

    # Start Bandit with our SSE Plug
    children = [
      {Bandit, plug: {MCP.Transport.SSE.Plug, [path: path, transport: self()]}, port: port}
    ]

    # Start the supervisor
    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    # Start a timer for regular pings to keep connections alive
    {:ok, timer} = :timer.send_interval(30_000, :ping_connections)

    {:ok,
     %{
       debug_mode: debug_mode,
       port: port,
       path: path,
       supervisor: supervisor,
       handler: nil,
       handler_ref: nil,
       connections: %{},
       timer: timer
     }}
  end

  # Handler for sending messages through all active SSE connections
  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    if state.debug_mode do
      Logger.debug("SSE transport sending: #{inspect(message)}")
    end

    # Convert the message to JSON string
    encoded = Jason.encode!(message)

    # Broadcast to all active connections
    Enum.each(state.connections, fn {_id, pid} ->
      send(pid, {:sse_event, encoded})
    end)

    {:reply, :ok, state}
  end

  # Handler for registering a process to receive incoming messages
  @impl GenServer
  def handle_call({:register_handler, handler_pid}, _from, state) do
    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end

    ref = Process.monitor(handler_pid)

    if state.debug_mode do
      Logger.debug("SSE transport registered new handler: #{inspect(handler_pid)}")
    end

    {:reply, :ok, %{state | handler: handler_pid, handler_ref: ref}}
  end

  # Handler for getting the current state
  @impl GenServer
  def handle_call(:get_state, _from, state) do
    # Return a sanitized state that doesn't include pids
    sanitized_state = %{
      debug_mode: state.debug_mode,
      port: state.port,
      path: state.path,
      connection_count: map_size(state.connections),
      has_handler: state.handler != nil
    }

    {:reply, {:ok, sanitized_state}, state}
  end

  # Handler for adding a new SSE connection
  def handle_call({:add_connection, id, pid}, _from, state) do
    if state.debug_mode do
      Logger.debug("SSE transport adding connection: #{id}")
    end

    # Monitor the connection process to detect disconnections
    ref = Process.monitor(pid)

    {:reply, :ok, %{state | connections: Map.put(state.connections, id, pid)}}
  end

  # Handler for incoming messages from the SSE connection
  @impl GenServer
  def handle_cast({:incoming_message, message}, %{handler: handler} = state)
      when is_pid(handler) do
    if state.debug_mode do
      Logger.debug("SSE transport received message: #{inspect(message)}")
    end

    # Parse the message and forward to the handler
    case Parser.parse(message) do
      {:ok, parsed} ->
        send(handler, {:mcp_message, parsed})

      {:error, reason} ->
        Logger.error("SSE transport failed to parse message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:incoming_message, _}, state) do
    Logger.warning("SSE transport received message but no handler is registered")
    {:noreply, state}
  end

  # Handler for removing an SSE connection
  @impl GenServer
  def handle_cast({:remove_connection, id}, state) do
    if state.debug_mode do
      Logger.debug("SSE transport removing connection: #{id}")
    end

    {:noreply, %{state | connections: Map.delete(state.connections, id)}}
  end

  # Handle ping timer
  @impl GenServer
  def handle_info(:ping_connections, state) do
    # Send ping to all connections
    Enum.each(state.connections, fn {_id, pid} ->
      send(pid, {:sse_ping})
    end)

    {:noreply, state}
  end

  # Handler for the DOWN message when a connection process exits
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Check if it's the handler
    if pid == state.handler do
      Logger.info("SSE handler process down: #{inspect(reason)}, unregistering")
      {:noreply, %{state | handler: nil, handler_ref: nil}}
    else
      # Find and remove the connection
      connection_id =
        Enum.find_value(state.connections, fn {id, conn_pid} ->
          if conn_pid == pid, do: id, else: nil
        end)

      if connection_id do
        Logger.debug("SSE connection #{connection_id} down: #{inspect(reason)}")
        {:noreply, %{state | connections: Map.delete(state.connections, connection_id)}}
      else
        {:noreply, state}
      end
    end
  end

  # Catch-all for other messages
  @impl GenServer
  def handle_info(message, state) do
    if state.debug_mode do
      Logger.debug("SSE transport received unexpected message: #{inspect(message)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("SSE transport terminating: #{inspect(reason)}")

    if state.handler_ref do
      Process.demonitor(state.handler_ref, [:flush])
    end

    # Cancel the timer
    if state.timer do
      :timer.cancel(state.timer)
    end

    # Stop the supervisor and all its children
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor, :normal)
    end

    :ok
  end
end
