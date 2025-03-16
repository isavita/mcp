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
    * `:transport` - The transport module to use (default: MCP.Transport.Stdio)
    * `:transport_opts` - Options to pass to the transport
    * `:debug_mode` - Enable debug logging (default: Application.get_env(:mcp, :debug, false))
    * `:name` - Optional name for the client process

  ## Example
      # Start a client using STDIO transport
      {:ok, client} = MCP.Client.start_link()

      # Start a client with debug enabled
      {:ok, client} = MCP.Client.start_link(debug_mode: true)
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
      {:ok, client} = MCP.Client.start_link()
      {:ok, capabilities} = MCP.Client.initialize(client)
  """
  def initialize(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    protocol_version = Keyword.get(opts, :protocol_version, "2024-11-05")
    client_name = Keyword.get(opts, :client_name, "Elixir MCP Client")
    client_version = Keyword.get(opts, :client_version, "0.1.0")

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:timeout` - How long to wait for a response (default: 30 seconds)

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
    * `:ok` - Notification was sent
    * `{:error, reason}` - Failed to send notification
  """
  def notify(client, notification) do
    GenServer.cast(client, {:notify, notification})
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

    if debug_mode do
      Logger.debug("Starting MCP client")
    end

    # Get the transport - either use existing or start a new one
    transport_result =
      if existing_transport do
        {:ok, existing_transport}
      else
        transport_mod.start_link(transport_opts)
      end

    case transport_result do
      {:ok, transport} ->
        # Subscribe to messages from the transport
        :ok = transport_mod.register_handler(transport, self())

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
        {:stop, {:transport_error, reason}}
    end
  end

  @impl GenServer
  def handle_call(:set_initialized, _from, state) do
    {:reply, :ok, %{state | initialized: true}}
  end

  @impl GenServer
  def handle_call({:request, request}, from, state) do
    if state.debug_mode do
      Logger.debug("Sending request: #{inspect(request)}")
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
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast({:notify, notification}, state) do
    if state.debug_mode do
      Logger.debug("Sending notification: #{inspect(notification)}")
    end

    # Send the notification through the transport
    case state.transport_mod.send_message(state.transport, notification) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to send notification: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:mcp_message, message}, state) do
    if state.debug_mode do
      Logger.debug("Client received message: #{inspect(message)}")
    end

    # Check if this is a response to a request we sent
    if Map.has_key?(message, "id") && Map.has_key?(state.pending_requests, message["id"]) do
      # Get the caller waiting for this response
      id = message["id"]
      {from, pending} = Map.pop(state.pending_requests, id)

      # Reply to the caller with the response
      GenServer.reply(from, {:ok, message})

      # Update state without this pending request
      {:noreply, %{state | pending_requests: pending}}
    else
      # This is a server-initiated request or notification
      Logger.info("Received server-initiated message: #{inspect(message)}")
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("MCP client terminating: #{inspect(reason)}")

    # Close the transport
    if state.transport do
      state.transport_mod.close(state.transport)
    end

    :ok
  end
end
