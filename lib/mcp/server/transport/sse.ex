defmodule MCP.Server.Transport.SSE do
  @moduledoc """
  Server-side SSE transport implementation for MCP.

  Listens for HTTP connections and manages SSE streams for clients.
  Implements the Streamable HTTP transport spec.
  """
  use GenServer
  require Logger

  alias MCP.Server.Transport.SSE.Plug

  @behaviour MCP.Transport.Behaviour

  # --- Public API ---

  @doc """
  Starts the SSE server transport.

  ## Options
    * `:port` (required) - Port to listen on.
    * `:path` (required) - HTTP path for MCP endpoint (e.g., "/mcp").
    * `:server_pid` (required) - PID of the `MCP.Server` process to forward messages to.
    * `:debug_mode` - Enable debug logging.
    * `:bandit_opts` - Additional options for Bandit.
  """
  @impl true
  def start_link(opts \\ []) do
    unless Keyword.has_key?(opts, :port), do: raise(ArgumentError, ":port option is required")
    unless Keyword.has_key?(opts, :path), do: raise(ArgumentError, ":path option is required")

    unless Keyword.has_key?(opts, :server_pid),
      do: raise(ArgumentError, ":server_pid option is required")

    GenServer.start_link(__MODULE__, opts, [])
  end

  @doc """
  Sends a message (response or notification) to a specific client connection.
  """
  def send_message(transport_pid, client_connection_id, message) do
    GenServer.cast(transport_pid, {:send_to_client, client_connection_id, message})
  end

  @doc """
  Closes the transport server.
  """
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl MCP.Transport.Behaviour
  def close(_), do: {:error, :use_public_close}

  # --- Transport Behaviour Callbacks (Adapting for Server) ---

  @impl MCP.Transport.Behaviour
  def send_message(_, _), do: {:error, :use_public_send_message_3}

  @impl MCP.Transport.Behaviour
  def register_handler(_, _), do: {:error, :not_applicable_for_server}

  @impl MCP.Transport.Behaviour
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.fetch!(opts, :path)
    server_pid = Keyword.fetch!(opts, :server_pid)
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))
    bandit_opts = Keyword.get(opts, :bandit_opts, [])

    if debug_mode do
      Logger.debug("Starting SSE Server Transport on port #{port}, path #{path}")
    end

    Process.flag(:trap_exit, true)
    Process.monitor(server_pid)

    # Configure Bandit to use our Plug
    plug_opts = [path: path, transport_pid: self()]
    bandit_config = [plug: {Plug, plug_opts}, port: port] ++ bandit_opts

    children = [{Bandit, bandit_config}]

    # Start Bandit under a supervisor
    sup_opts = [
      strategy: :one_for_one,
      name: :"#{__MODULE__}.Supervisor#{System.unique_integer()}"
    ]

    case Supervisor.start_link(children, sup_opts) do
      {:ok, supervisor} ->
        state = %{
          debug_mode: debug_mode,
          port: port,
          path: path,
          server_pid: server_pid,
          supervisor: supervisor,
          # Map of conn_id -> %{pid: plug_process_pid, ref: monitor_ref}
          connections: %{},
          server_pid_ref: Process.monitor(server_pid)
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("SSE Server Transport failed to start Bandit: #{inspect(reason)}")
        {:stop, {:bandit_start_failed, reason}}
    end
  end

  # --- Internal Message Handling ---

  # Message from Plug: A new client connected via GET (SSE stream established)
  @impl GenServer
  def handle_call({:client_connected, conn_id, plug_pid}, _from, state) do
    if state.debug_mode do
      Logger.debug("SSE Transport: Client connected #{conn_id} via #{inspect(plug_pid)}")
    end

    ref = Process.monitor(plug_pid)
    new_connections = Map.put(state.connections, conn_id, %{pid: plug_pid, ref: ref})

    # Notify the main MCP.Server
    send(state.server_pid, {:client_connected, self(), conn_id})

    {:reply, :ok, %{state | connections: new_connections}}
  end

  # Message from Plug: Client disconnected (SSE stream closed or POST finished)
  @impl GenServer
  def handle_call({:client_disconnected, conn_id}, _from, state) do
    if state.debug_mode do
      Logger.debug("SSE Transport: Client disconnected #{conn_id}")
    end

    # Clean up monitor if connection exists
    if conn_info = Map.get(state.connections, conn_id) do
      Process.demonitor(conn_info.ref, [:flush])
    end

    new_connections = Map.delete(state.connections, conn_id)

    # Notify the main MCP.Server
    send(state.server_pid, {:client_disconnected, self(), conn_id})

    {:reply, :ok, %{state | connections: new_connections}}
  end

  # Message from Plug: Received data from client via POST
  @impl GenServer
  def handle_call({:incoming_message, conn_id, raw_json}, _from, state) do
    if state.debug_mode do
      Logger.debug("SSE Transport: Received POST from #{conn_id}: #{inspect(raw_json)}")
    end

    # Forward to the main MCP.Server, associating with the connection ID
    send(state.server_pid, {:mcp_message, {self(), conn_id, raw_json}})

    # Acknowledge receipt to the Plug
    {:reply, :ok, state}
  end

  # Get state for introspection
  @impl GenServer
  def handle_call(:get_state, _from, state) do
    safe_state =
      Map.drop(state, [:supervisor, :connections, :server_pid_ref])
      |> Map.put(:connection_count, map_size(state.connections))

    {:reply, {:ok, safe_state}, state}
  end

  # Message from MCP.Server: Send data to a specific client via SSE
  @impl GenServer
  def handle_cast({:send_to_client, conn_id, message}, state) do
    if conn_info = Map.get(state.connections, conn_id) do
      if state.debug_mode do
        Logger.debug("SSE Transport: Sending to #{conn_id}: #{inspect(message)}")
      end

      # The Plug process handles the actual SSE formatting and sending
      send(conn_info.pid, {:send_sse_event, message})
    else
      Logger.warning("SSE Transport: Attempted to send to unknown connection #{conn_id}")
    end

    {:noreply, state}
  end

  # --- Monitoring and Termination ---

  # Handle DOWN message if a Plug process (client connection) dies
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Check if this is the server_pid monitor
    if ref == state.server_pid_ref and pid == state.server_pid do
      Logger.error(
        "SSE Transport: Main MCP Server process died: #{inspect(reason)}. Stopping transport."
      )

      {:stop, :server_process_died, state}
    else
      # Find connection by monitor ref and remove it
      case Enum.find(state.connections, fn {_id, %{ref: r}} -> r == ref end) do
        {conn_id, _conn_info} ->
          if state.debug_mode do
            Logger.debug("SSE Transport: Plug process for #{conn_id} down: #{inspect(reason)}")
          end

          new_connections = Map.delete(state.connections, conn_id)
          # Notify the main MCP.Server
          send(state.server_pid, {:client_disconnected, self(), conn_id})
          {:noreply, %{state | connections: new_connections}}

        _ ->
          # Unknown monitor ref
          {:noreply, state}
      end
    end
  end

  # Catch-all for other messages
  @impl GenServer
  def handle_info(message, state) do
    if state.debug_mode do
      Logger.debug("SSE Server Transport received unexpected message: #{inspect(message)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("SSE Server Transport terminating: #{inspect(reason)}")
    # Stop the Bandit supervisor
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor, :shutdown)
    end

    :ok
  end
end
