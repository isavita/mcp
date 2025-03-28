defmodule MCP.Client do
  @moduledoc """
  Client for communicating with an MCP server.

  This module provides a high-level API for sending requests to an MCP server
  and handling responses. It manages request/response correlation and provides
  both synchronous and asynchronous interfaces.
  """

  use GenServer
  require Logger
  alias MCP.Protocol.Formatter

  @default_timeout 5_000

  # Client API

  @doc """
  Starts a new MCP client that communicates with a server.

  ## Options
    * `:transport` - The transport module to use (default: `MCP.Transport.Stdio`).
    * `:transport_opts` - Options to pass to the transport's `start_link/1`.
      * For `MCP.Transport.Stdio`, this **must** include a `:command` key specifying the server command string. Example: `transport_opts: [command: "npx ..."]`.
    * `:debug_mode` - Enable debug logging (default: `Application.get_env(:mcp, :debug, false)`).
    * `:name` - Optional name for the client process.

  ## Example
      # Start a client using STDIO transport with an external server
      {:ok, client} = MCP.Client.start_link(
        transport_opts: [command: "npx -y @modelcontextprotocol/server-filesystem /path/to/my/data"]
      )

      # Start a client with debug enabled
      {:ok, client} = MCP.Client.start_link(
        debug_mode: true,
        transport_opts: [command: "my_mcp_server --stdio"]
      )
  """
  def start_link(opts \\ []) do
    {name_opt, client_opts} = Keyword.pop(opts, :name)

    if name_opt do
      GenServer.start_link(__MODULE__, client_opts, name: name_opt)
    else
      GenServer.start_link(__MODULE__, client_opts)
    end
  end

  @doc """
  Initializes the client's connection to the server.

  This sends the initialize request to establish capabilities with the server.

  ## Example
      {:ok, client} = MCP.Client.start_link(transport_opts: [command: "..."])
      {:ok, capabilities} = MCP.Client.initialize(client)
  """
  def initialize(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    protocol_version = Keyword.get(opts, :protocol_version, "2024-11-05")
    client_name = Keyword.get(opts, :client_name, "Elixir MCP Client")
    # Use library version
    client_version = Keyword.get(opts, :client_version, MCP.version())

    request =
      Formatter.initialize_request(
        protocol_version,
        client_name,
        client_version
      )

    case request(client, request, timeout) do
      {:ok, response} ->
        # Mark the client as initialized internally
        GenServer.call(client, :set_initialized)

        # Return capabilities from the server's response
        {:ok, response["result"]}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Pings the server to check if it's still alive.

  ## Options
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, _} = MCP.Client.ping(client)
  """
  def ping(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    request = Formatter.ping_request()

    case request(client, request, timeout) do
      {:ok, _response} -> {:ok, :pong}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists resources available on the server.

  ## Options
    * `:cursor` - Pagination cursor for continuing a previous list operation
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, resources} = MCP.Client.list_resources(client)
  """
  def list_resources(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cursor = Keyword.get(opts, :cursor)

    request = Formatter.list_resources_request(cursor)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads a resource from the server.

  ## Parameters
    * `uri` - URI of the resource to read

  ## Options
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, content} = MCP.Client.read_resource(client, "file:///path/to/resource")
  """
  def read_resource(client, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request = Formatter.read_resource_request(uri)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists available prompts on the server.

  ## Options
    * `:cursor` - Pagination cursor for continuing a previous list operation
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, prompts} = MCP.Client.list_prompts(client)
  """
  def list_prompts(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cursor = Keyword.get(opts, :cursor)

    request = Formatter.list_prompts_request(cursor)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets a prompt from the server.

  ## Parameters
    * `name` - Name of the prompt to retrieve

  ## Options
    * `:arguments` - Arguments to use when templating the prompt
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, prompt} = MCP.Client.get_prompt(client, "greeting_prompt", arguments: %{"name" => "John"})
  """
  def get_prompt(client, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    arguments = Keyword.get(opts, :arguments)

    request = Formatter.get_prompt_request(name, arguments)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists available tools on the server.

  ## Options
    * `:cursor` - Pagination cursor for continuing a previous list operation
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, tools} = MCP.Client.list_tools(client)
  """
  def list_tools(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cursor = Keyword.get(opts, :cursor)

    request = Formatter.list_tools_request(cursor)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Calls a tool on the server.

  ## Parameters
    * `name` - Name of the tool to call

  ## Options
    * `:arguments` - Arguments to pass to the tool
    * `:timeout` - How long to wait for a response (default: 5 seconds)

  ## Example
      {:ok, result} = MCP.Client.call_tool(client, "calculator", arguments: %{"op" => "add", "a" => 5, "b" => 3})
  """
  def call_tool(client, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    arguments = Keyword.get(opts, :arguments)

    request = Formatter.call_tool_request(name, arguments)

    case request(client, request, timeout) do
      {:ok, response} -> {:ok, response["result"]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sends a raw request to the server and waits for a response.

  This is a low-level function that handles request/response correlation.
  Most users should use the higher-level API functions instead.

  ## Parameters
    * `request` - A map representing the JSON-RPC request
    * `timeout` - How long to wait for a response

  ## Returns
    * `{:ok, response}` - Successfully received a response
    * `{:error, reason}` - Failed to receive a response
  """
  def request(client, request, timeout \\ @default_timeout) do
    GenServer.call(client, {:request, request}, timeout)
  end

  @doc """
  Sends a notification to the server (no response expected).

  ## Parameters
    * `notification` - A map representing the JSON-RPC notification

  ## Returns
    * `:ok` - Notification was sent successfully via the transport call.
    * `{:error, reason}` - Failed to send notification (error returned by transport).
  """
  def notify(client, notification) do
    # Use call to get immediate feedback from the transport about sending
    GenServer.call(client, {:notify, notification})
  end

  @doc """
  Sends an initialized notification to the server.

  This should be sent after successful initialization.

  ## Returns
    * `:ok` - Notification was sent
    * `{:error, reason}` - Failed to send notification
  """
  def send_initialized(client) do
    notification = Formatter.initialized_notification()
    notify(client, notification)
  end

  @doc """
  Closes the client connection and terminates the process.
  """
  def close(client) do
    GenServer.stop(client, :normal)
  end

  # GenServer Implementation

  @impl GenServer
  def init(opts) do
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))
    transport_mod = Keyword.get(opts, :transport, MCP.Transport.Stdio)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    existing_transport = Keyword.get(opts, :existing_transport)

    # Ensure debug_mode is passed down if not explicitly set in transport_opts
    transport_opts = Keyword.put_new(transport_opts, :debug_mode, debug_mode)

    if debug_mode do
      Logger.debug("Starting MCP client with transport #{inspect(transport_mod)}")
      Logger.debug("Transport options: #{inspect(transport_opts)}")
    end

    # Get the transport - either use existing or start a new one
    transport_result =
      if existing_transport do
        {:ok, existing_transport}
      else
        # Check required options for specific transports
        if transport_mod == MCP.Transport.Stdio && !Keyword.has_key?(transport_opts, :command) do
          {:error, :missing_command_option}
        else
          transport_mod.start_link(transport_opts)
        end
      end

    case transport_result do
      {:ok, transport} ->
        # Subscribe to messages from the transport
        case transport_mod.register_handler(transport, self()) do
          :ok ->
            # Monitor the transport process
            Process.monitor(transport)
            # Return initial state
            {:ok,
             %{
               debug_mode: debug_mode,
               transport: transport,
               transport_mod: transport_mod,
               pending_requests: %{},
               initialized: false
             }}

          {:error, reason} ->
            Logger.error("Failed to register client with transport: #{inspect(reason)}")
            # Ensure transport is stopped if registration fails
            if !existing_transport, do: transport_mod.close(transport)
            {:stop, {:transport_registration_failed, reason}}
        end

      {:error, :missing_command_option} ->
        Logger.error(
          "MCP.Client failed to start: :command option missing in :transport_opts for MCP.Transport.Stdio"
        )

        {:stop, :missing_command_option}

      {:error, reason} ->
        Logger.error("MCP.Client failed to start transport: #{inspect(reason)}")
        {:stop, {:transport_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:set_initialized, _from, state) do
    {:reply, :ok, %{state | initialized: true}}
  end

  @impl GenServer
  def handle_call({:request, request}, from, state) do
    if state.debug_mode do
      Logger.debug("Client sending request: #{inspect(request)}")
    end

    # Get the request ID for correlation
    id = request["id"]

    # Send the request through the transport
    case state.transport_mod.send_message(state.transport, request) do
      :ok ->
        # Store the caller to reply when we get a response
        pending = Map.put(state.pending_requests, id, from)

        # Don't reply now, we'll reply when we get the response
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        Logger.error("Client failed to send request via transport: #{inspect(reason)}")
        {:reply, {:error, {:transport_send_failed, reason}}, state}
    end
  end

  # Changed notify to handle_call to get immediate feedback
  @impl GenServer
  def handle_call({:notify, notification}, _from, state) do
    if state.debug_mode do
      Logger.debug("Client sending notification: #{inspect(notification)}")
    end

    # Send the notification through the transport
    case state.transport_mod.send_message(state.transport, notification) do
      :ok ->
        # Reply immediately on successful send call
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Client failed to send notification via transport: #{inspect(reason)}")
        {:reply, {:error, {:transport_send_failed, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    if state.debug_mode do
      Logger.debug("Client received message from transport: #{inspect(message)}")
    end

    # Check if this is a response to a request we sent
    # Need to handle potential nil ID in error responses from parse errors
    case Map.get(message, "id") do
      nil ->
        # Could be a notification from the server, or a parse error response
        Logger.info(
          "Client received message without ID (Notification or Parse Error Response): #{inspect(message)}"
        )

        # TODO: Add handling for server-initiated notifications if needed
        {:noreply, state}

      id ->
        # Check if it's a response we are waiting for
        case Map.pop(state.pending_requests, id) do
          {nil, _state} ->
            Logger.warning(
              "Client received response for unknown or timed-out ID #{inspect(id)}: #{inspect(message)}"
            )
            {:noreply, state}
          {from, pending} ->
            # Reply to the original caller with the response
            GenServer.reply(from, {:ok, message})
            # Update state without this pending request
            {:noreply, %{state | pending_requests: pending}}
        end
    end
  end

  # Handle transport termination unexpectedly
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{transport: pid} = state) do
    Logger.error("MCP transport process terminated unexpectedly: #{inspect(reason)}")
    # Reply with errors to all pending requests
    for {id, from} <- state.pending_requests do
      # Use try/catch as the caller might already be dead
      try do
        GenServer.reply(from, {:error, {:transport_terminated, reason}})
        Logger.debug("Replied with error to pending request #{inspect(id)}")
      catch
        # Ignore if caller is dead
        :exit, _ -> :ok
      end
    end

    # Stop the client
    {:stop, {:transport_terminated, reason}, %{state | transport: nil, pending_requests: %{}}}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("MCP client terminating: #{inspect(reason)}")

    # Reply with errors to any remaining pending requests if termination wasn't normal
    if reason != :normal and reason != :shutdown do
      for {id, from} <- state.pending_requests do
        # Use try/catch as the caller might already be dead
        try do
          GenServer.reply(from, {:error, {:client_terminated, reason}})
          Logger.debug("Replied with error to pending request #{inspect(id)} during termination")
        catch
          # Ignore if caller is dead
          :exit, _ -> :ok
        end
      end
    end

    # Close the transport if it's still alive and we started it
    # (Checking if transport is pid and alive)
    if is_pid(state.transport) and Process.alive?(state.transport) do
      # Avoid closing if it was an existing transport passed in?
      # For now, assume client owns the transport lifecycle if it started it.
      Logger.debug("Client closing transport #{inspect(state.transport)}")
      state.transport_mod.close(state.transport)
    end

    :ok
  end
end
