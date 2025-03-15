defmodule MCP.Formatter do
  @moduledoc """
  Formats messages for the Model Context Protocol according to the JSON-RPC 2.0 specification.

  This module provides functions to create properly formatted JSON-RPC messages for
  various MCP operations, using string keys to match the specification exactly.
  """

  @doc """
  Creates a properly formatted JSON-RPC 2.0 request.

  ## Parameters
    * `method` - The method to call
    * `params` - The parameters for the method (optional)
    * `id` - The request ID (defaults to a random UUID if not provided)

  ## Returns
    A map representing a properly formatted JSON-RPC request
  """
  @spec create_request(String.t(), map() | nil, String.t() | integer() | nil) :: map()
  def create_request(method, params \\ nil, id \\ nil) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id || random_id()
    }

    if params, do: Map.put(request, "params", params), else: request
  end

  @doc """
  Creates a properly formatted JSON-RPC 2.0 notification (a request without an ID).

  ## Parameters
    * `method` - The method to call
    * `params` - The parameters for the method (optional)

  ## Returns
    A map representing a properly formatted JSON-RPC notification
  """
  @spec create_notification(String.t(), map() | nil) :: map()
  def create_notification(method, params \\ nil) do
    notification = %{"jsonrpc" => "2.0", "method" => method}

    if params, do: Map.put(notification, "params", params), else: notification
  end

  @doc """
  Creates a properly formatted JSON-RPC 2.0 success response.

  ## Parameters
    * `id` - The ID of the request being responded to
    * `result` - The result of the method call

  ## Returns
    A map representing a properly formatted JSON-RPC success response
  """
  @spec create_success_response(String.t() | integer(), map() | nil) :: map()
  def create_success_response(id, result \\ nil) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id
    }

    response =
      if result, do: Map.put(response, "result", result), else: Map.put(response, "result", %{})

    response
  end

  @doc """
  Creates a properly formatted JSON-RPC 2.0 error response.

  ## Parameters
    * `id` - The ID of the request being responded to
    * `error_code` - The error code
    * `error_message` - A short description of the error
    * `error_data` - Additional error information (optional)

  ## Returns
    A map representing a properly formatted JSON-RPC error response
  """
  @spec create_error_response(String.t() | integer() | nil, integer(), String.t(), any() | nil) ::
          map()
  def create_error_response(id, error_code, error_message, error_data \\ nil) do
    error = %{
      "code" => error_code,
      "message" => error_message
    }

    error = if error_data, do: Map.put(error, "data", error_data), else: error

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    }
  end

  @doc """
  Encodes a request object to a JSON string with proper newline termination.

  ## Parameters
    * `message` - The message to encode

  ## Returns
    A JSON string with a trailing newline
  """
  @spec encode(map()) :: String.t()
  def encode(message) do
    Jason.encode!(message) <> "\n"
  end

  # MCP-specific message formatters

  @doc """
  Creates an initialize request according to the MCP specification.

  ## Parameters
    * `protocol_version` - The MCP protocol version
    * `client_name` - The name of the client
    * `client_version` - The client version
    * `capabilities` - Client capabilities (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP initialize request
  """
  @spec initialize_request(
          String.t(),
          String.t(),
          String.t(),
          map() | nil,
          String.t() | integer() | nil
        ) :: map()
  def initialize_request(
        protocol_version,
        client_name,
        client_version,
        capabilities \\ nil,
        id \\ nil
      ) do
    params = %{
      "protocolVersion" => protocol_version,
      "clientInfo" => %{
        "name" => client_name,
        "version" => client_version
      },
      "capabilities" =>
        capabilities ||
          %{
            "roots" => %{
              "listChanged" => true
            },
            "sampling" => %{}
          }
    }

    create_request("initialize", params, id)
  end

  @doc """
  Creates a ping request according to the MCP specification.

  ## Parameters
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP ping request
  """
  @spec ping_request(String.t() | integer() | nil) :: map()
  def ping_request(id \\ nil) do
    create_request("ping", %{}, id)
  end

  @doc """
  Creates a resources/list request according to the MCP specification.

  ## Parameters
    * `cursor` - Pagination cursor (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP resources/list request
  """
  @spec list_resources_request(String.t() | nil, String.t() | integer() | nil) :: map()
  def list_resources_request(cursor \\ nil, id \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    create_request("resources/list", params, id)
  end

  @doc """
  Creates a resources/read request according to the MCP specification.

  ## Parameters
    * `uri` - The URI of the resource to read
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP resources/read request
  """
  @spec read_resource_request(String.t(), String.t() | integer() | nil) :: map()
  def read_resource_request(uri, id \\ nil) do
    create_request("resources/read", %{"uri" => uri}, id)
  end

  @doc """
  Creates a prompts/list request according to the MCP specification.

  ## Parameters
    * `cursor` - Pagination cursor (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP prompts/list request
  """
  @spec list_prompts_request(String.t() | nil, String.t() | integer() | nil) :: map()
  def list_prompts_request(cursor \\ nil, id \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    create_request("prompts/list", params, id)
  end

  @doc """
  Creates a prompts/get request according to the MCP specification.

  ## Parameters
    * `name` - The name of the prompt
    * `arguments` - Arguments to use for templating the prompt (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP prompts/get request
  """
  @spec get_prompt_request(String.t(), map() | nil, String.t() | integer() | nil) :: map()
  def get_prompt_request(name, arguments \\ nil, id \\ nil) do
    params = %{"name" => name}
    params = if arguments, do: Map.put(params, "arguments", arguments), else: params

    create_request("prompts/get", params, id)
  end

  @doc """
  Creates a tools/list request according to the MCP specification.

  ## Parameters
    * `cursor` - Pagination cursor (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP tools/list request
  """
  @spec list_tools_request(String.t() | nil, String.t() | integer() | nil) :: map()
  def list_tools_request(cursor \\ nil, id \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    create_request("tools/list", params, id)
  end

  @doc """
  Creates a tools/call request according to the MCP specification.

  ## Parameters
    * `name` - The name of the tool to call
    * `arguments` - Arguments for the tool (optional)
    * `id` - The request ID (optional)

  ## Returns
    A map representing a properly formatted MCP tools/call request
  """
  @spec call_tool_request(String.t(), map() | nil, String.t() | integer() | nil) :: map()
  def call_tool_request(name, arguments \\ nil, id \\ nil) do
    params = %{"name" => name}
    params = if arguments, do: Map.put(params, "arguments", arguments), else: params

    create_request("tools/call", params, id)
  end

  @doc """
  Creates an initialized notification according to the MCP specification.

  ## Returns
    A map representing a properly formatted MCP initialized notification
  """
  @spec initialized_notification() :: map()
  def initialized_notification do
    create_notification("notifications/initialized")
  end

  @doc """
  Creates a roots/list_changed notification according to the MCP specification.

  ## Returns
    A map representing a properly formatted MCP roots list changed notification
  """
  @spec roots_list_changed_notification() :: map()
  def roots_list_changed_notification do
    create_notification("notifications/roots/list_changed")
  end

  @doc """
  Creates a cancelled notification according to the MCP specification.

  ## Parameters
    * `request_id` - The ID of the request being cancelled
    * `reason` - The reason for cancellation (optional)

  ## Returns
    A map representing a properly formatted MCP cancelled notification
  """
  @spec cancelled_notification(String.t() | integer(), String.t() | nil) :: map()
  def cancelled_notification(request_id, reason \\ nil) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params

    create_notification("notifications/cancelled", params)
  end

  # Private helpers

  defp random_id, do: UUID.uuid4()
end
