defmodule MCP.Server do
  @moduledoc """
  Core GenServer for managing an MCP Server instance.

  Handles communication with clients via transports, manages server state
  (capabilities, registered features), and dispatches requests.
  """
  use GenServer
  require Logger

  alias MCP.Protocol.{Formatter, Validator}

  @default_protocol_version "2025-03-26"

  # --- Public API ---

  @doc """
  Starts a new MCP server process.

  ## Options
    * `:transport` (required) - The transport module to use (e.g., `MCP.Server.Transport.SSE`).
    * `:transport_opts` (required) - Options passed to the transport's `start_link/1`.
    * `:features` - A list of feature modules or explicit tool/resource/prompt definitions.
    * `:debug_mode` - Enable debug logging (default: `Application.get_env(:mcp, :debug, false)`).
    * `:name` - Optional name for the server process.
    * `:protocol_version` - Protocol version the server supports (default: `#{@default_protocol_version}`).
    * `:server_info` - Map containing server name and version (e.g., `%{name: "MyElixirServer", version: "0.1.0"}`).
  """
  def start_link(opts \\ []) do
    {name_opt, server_opts} = Keyword.pop(opts, :name)
    gen_opts = if name_opt, do: [name: name_opt], else: []
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @doc """
  Sends a notification to a specific client connection.
  """
  def send_notification(server_pid, transport_pid, client_connection_id, notification) do
    GenServer.call(
      server_pid,
      {:send_notification, transport_pid, client_connection_id, notification}
    )
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(opts) do
    debug_mode = Keyword.get(opts, :debug_mode, Application.get_env(:mcp, :debug, false))
    transport_mod = Keyword.fetch!(opts, :transport)
    transport_opts = Keyword.fetch!(opts, :transport_opts)
    # Default to ElixirAppInfo feature
    features = Keyword.get(opts, :features, [MCP.Server.Features.ElixirAppInfo])
    protocol_version = Keyword.get(opts, :protocol_version, @default_protocol_version)

    server_info =
      Keyword.get(
        opts,
        :server_info,
        %{name: "Elixir MCP Server", version: MCP.version()}
      )

    if debug_mode do
      Logger.debug("Starting MCP Server with transport #{inspect(transport_mod)}")
    end

    # Start the transport
    transport_opts = Keyword.put(transport_opts, :server_pid, self())
    transport_opts = Keyword.put_new(transport_opts, :debug_mode, debug_mode)

    case transport_mod.start_link(transport_opts) do
      {:ok, transport} ->
        Process.monitor(transport)

        # Register features (tools, resources, prompts)
        # For simplicity, we'll focus on tools from modules for now
        tools = load_tools_from_modules(features)

        state = %{
          debug_mode: debug_mode,
          transport: transport,
          transport_mod: transport_mod,
          protocol_version: protocol_version,
          server_info: server_info,
          # Store tools by name
          tools: Map.new(tools, fn {name, tool_def} -> {name, tool_def} end),
          # Placeholder
          resources: %{},
          # Placeholder
          prompts: %{},
          # Map of {transport_pid, conn_id} -> %{capabilities: nil}
          client_connections: %{}
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("MCP Server failed to start transport: #{inspect(reason)}")
        {:stop, {:transport_start_failed, reason}}
    end
  end

  # --- Message Handling from Transport ---

  @impl GenServer
  def handle_info({:mcp_message, {transport_pid, client_connection_id, message}}, state) do
    if state.debug_mode do
      Logger.debug(
        "Server received message from #{inspect(client_connection_id)}: #{inspect(message)}"
      )
    end

    # Process the message based on its type
    case Validator.validate_request(message) do
      {:ok, request} ->
        handle_mcp_request(request, transport_pid, client_connection_id, state)

      _ ->
        case Validator.validate_notification(message) do
          {:ok, notification} ->
            handle_mcp_notification(notification, transport_pid, client_connection_id, state)

          _ ->
            # Could be a response, but servers don't typically send requests needing responses
            # Or it could be an invalid message
            Logger.warning(
              "Server received unhandled or invalid message from #{inspect(client_connection_id)}: #{inspect(message)}"
            )

            # Maybe send a generic error response if it had an ID?
            if id = message["id"] do
              error_resp =
                Formatter.create_error_response(id, -32_600, "Invalid Request", message)

              # FIX: Add transport_pid here
              send_response(
                state.transport_mod,
                transport_pid,
                client_connection_id,
                error_resp,
                state.debug_mode
              )
            end

            {:noreply, state}
        end
    end
  end

  # Handle client connection registration from transport
  @impl GenServer
  def handle_info({:client_connected, transport_pid, client_connection_id}, state) do
    if state.debug_mode do
      Logger.debug("Server noted client connected: #{inspect(client_connection_id)}")
    end

    new_connections =
      Map.put(state.client_connections, {transport_pid, client_connection_id}, %{
        capabilities: nil
      })

    {:noreply, %{state | client_connections: new_connections}}
  end

  # Handle client disconnection from transport
  @impl GenServer
  def handle_info({:client_disconnected, transport_pid, client_connection_id}, state) do
    if state.debug_mode do
      Logger.debug("Server noted client disconnected: #{inspect(client_connection_id)}")
    end

    new_connections = Map.delete(state.client_connections, {transport_pid, client_connection_id})
    {:noreply, %{state | client_connections: new_connections}}
  end

  # Handle transport termination
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{transport: pid} = state) do
    Logger.error("MCP Server's transport process terminated unexpectedly: #{inspect(reason)}")
    # Stop the server itself
    {:stop, {:transport_terminated, reason}, state}
  end

  # Catch-all for other messages
  @impl GenServer
  def handle_info(message, state) do
    if state.debug_mode do
      Logger.debug("Server received unexpected message: #{inspect(message)}")
    end

    {:noreply, state}
  end

  # --- Call Handling (e.g., for sending notifications) ---
  @impl GenServer
  def handle_call(
        {:send_notification, transport_pid, client_connection_id, notification},
        _from,
        state
      ) do
    result =
      send_response(
        state.transport_mod,
        transport_pid,
        client_connection_id,
        notification,
        state.debug_mode
      )

    {:reply, result, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("MCP Server terminating: #{inspect(reason)}")

    # Close the transport if it's still alive
    if is_pid(state.transport) and Process.alive?(state.transport) do
      Logger.debug("Server closing transport #{inspect(state.transport)}")
      state.transport_mod.close(state.transport)
    end

    :ok
  end

  # --- Private Helper Functions ---

  # Load tools defined in feature modules
  defp load_tools_from_modules(modules) do
    Enum.flat_map(modules, fn module ->
      # Ensure the check is correct if the module name changed
      if function_exported?(module, :mcp_tools, 0) do
        module.mcp_tools()
      else
        Logger.warning("Feature module #{inspect(module)} does not export mcp_tools/0")
        []
      end
    end)
  end

  # Handle specific MCP requests
  defp handle_mcp_request(
         # Match more specifically, ignore full request map
         %{"method" => "initialize", "id" => id, "params" => params},
         transport_pid,
         client_connection_id,
         state
       ) do
    client_caps = Map.get(params, "capabilities", %{})
    client_info = Map.get(params, "clientInfo", %{})

    if state.debug_mode do
      Logger.debug(
        "Server received initialize from #{inspect(client_info)} with caps #{inspect(client_caps)}"
      )
    end

    # Store client capabilities
    updated_connections =
      Map.put(state.client_connections, {transport_pid, client_connection_id}, %{
        capabilities: client_caps
      })

    # Respond with server capabilities
    response =
      Formatter.create_success_response(id, %{
        "protocolVersion" => state.protocol_version,
        "serverInfo" => state.server_info,
        "capabilities" => build_server_capabilities(state)
        # "instructions" => "Optional instructions here"
      })

    send_response(
      state.transport_mod,
      transport_pid,
      client_connection_id,
      response,
      state.debug_mode
    )

    {:noreply, %{state | client_connections: updated_connections}}
  end

  defp handle_mcp_request(
         %{"method" => "ping", "id" => id},
         transport_pid,
         client_connection_id,
         state
       ) do
    response = Formatter.create_success_response(id, %{})

    send_response(
      state.transport_mod,
      transport_pid,
      client_connection_id,
      response,
      state.debug_mode
    )

    {:noreply, state}
  end

  defp handle_mcp_request(
         %{"method" => "tools/list", "id" => id},
         transport_pid,
         client_connection_id,
         state
       ) do
    # TODO: Add pagination support
    tool_list =
      Enum.map(state.tools, fn {_, tool_def} ->
        %{
          "name" => tool_def.name,
          "description" => tool_def.description,
          "inputSchema" => tool_def.input_schema
          # "annotations" => tool_def.annotations # Add if defined
        }
      end)

    response = Formatter.create_success_response(id, %{"tools" => tool_list})

    send_response(
      state.transport_mod,
      transport_pid,
      client_connection_id,
      response,
      state.debug_mode
    )

    {:noreply, state}
  end

  defp handle_mcp_request(
         %{"method" => "tools/call", "id" => id, "params" => params} = request,
         transport_pid,
         client_connection_id,
         state
       ) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case Map.get(state.tools, tool_name) do
      nil ->
        # Tool not found
        error_resp = Formatter.create_error_response(id, -32_601, "Method not found", request)

        send_response(
          state.transport_mod,
          transport_pid,
          client_connection_id,
          error_resp,
          state.debug_mode
        )

      %{handler: handler_fun} ->
        # Execute the tool handler
        # Wrap in Task for potential async/long-running tools, but respond synchronously for now
        # A more robust implementation would handle async results and progress.
        try do
          # Pass exchange context if needed (e.g., client caps, ability to send notifications)
          exchange_context = %{
            client_capabilities:
              Map.get(
                state.client_connections,
                {transport_pid, client_connection_id},
                %{}
              )[:capabilities] || %{},
            server_pid: self(),
            transport_pid: transport_pid,
            client_connection_id: client_connection_id
          }

          result_content = apply(handler_fun, [exchange_context, arguments])

          # Assume handler returns list of content blocks or simple string
          content_list =
            case result_content do
              [%{"type" => _} | _] = list -> list
              string when is_binary(string) -> [%{"type" => "text", "text" => string}]
              # Fallback
              other -> [%{"type" => "text", "text" => inspect(other)}]
            end

          response =
            Formatter.create_success_response(id, %{
              "content" => content_list,
              "isError" => false
            })

          send_response(
            state.transport_mod,
            transport_pid,
            client_connection_id,
            response,
            state.debug_mode
          )
        rescue
          e ->
            stacktrace = __STACKTRACE__

            Logger.error(
              "Error executing tool '#{tool_name}': #{inspect(e)}\n#{inspect(stacktrace)}"
            )

            error_resp =
              Formatter.create_error_response(id, -32_000, "Tool execution error", %{
                tool: tool_name,
                error: Exception.message(e)
              })

            send_response(
              state.transport_mod,
              transport_pid,
              client_connection_id,
              error_resp,
              state.debug_mode
            )
        end
    end

    {:noreply, state}
  end

  # Fallback for unknown requests
  defp handle_mcp_request(request, transport_pid, client_connection_id, state) do
    id = request["id"]
    method = request["method"]

    Logger.warning(
      "Server received unknown request method '#{method}' from #{inspect(client_connection_id)}"
    )

    error_resp = Formatter.create_error_response(id, -32_601, "Method not found", request)

    send_response(
      state.transport_mod,
      transport_pid,
      client_connection_id,
      error_resp,
      state.debug_mode
    )

    {:noreply, state}
  end

  # Handle specific MCP notifications
  defp handle_mcp_notification(
         %{"method" => "notifications/initialized"},
         _transport_pid,
         _client_connection_id,
         state
       ) do
    # Client confirmed initialization, server is ready for full operation with this client
    if state.debug_mode do
      Logger.debug("Server received initialized notification.")
    end

    {:noreply, state}
  end

  defp handle_mcp_notification(
         %{"method" => "notifications/cancelled", "params" => params},
         _transport_pid,
         _client_connection_id,
         state
       ) do
    request_id = params["requestId"]
    reason = params["reason"]

    if state.debug_mode do
      Logger.debug(
        "Server received cancellation for request #{inspect(request_id)}. Reason: #{inspect(reason)}"
      )
    end

    # TODO: Implement actual cancellation logic if server supports it
    # (e.g., kill associated task)
    {:noreply, state}
  end

  # Fallback for unknown notifications
  defp handle_mcp_notification(notification, _transport_pid, client_connection_id, state) do
    method = notification["method"]

    Logger.warning(
      "Server received unknown notification method '#{method}' from #{inspect(client_connection_id)}"
    )

    {:noreply, state}
  end

  # Build the server capabilities map based on registered features
  defp build_server_capabilities(state) do
    %{
      "tools" => if(map_size(state.tools) > 0, do: %{"listChanged" => true}, else: nil),
      "resources" => if(map_size(state.resources) > 0, do: %{"listChanged" => true}, else: nil),
      "prompts" => if(map_size(state.prompts) > 0, do: %{"listChanged" => true}, else: nil),
      # Always support logging for now
      "logging" => %{}
      # "completions" => %{} # Add if completion is supported
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Helper to send response/notification via transport
  defp send_response(transport_mod, transport_pid, client_connection_id, message, debug_mode) do
    if debug_mode do
      Logger.debug(
        "Server sending to #{inspect(client_connection_id)} via #{inspect(transport_pid)}: #{inspect(message)}"
      )
    end

    # Use the specific transport_pid provided
    transport_mod.send_message(transport_pid, client_connection_id, message)
  end
end
