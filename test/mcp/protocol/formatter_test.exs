defmodule MCP.Protocol.FormatterTest do
  use ExUnit.Case, async: true
  doctest MCP.Protocol.Formatter

  alias MCP.Protocol.Formatter

  describe "create_request/3" do
    test "creates a valid request with all parameters" do
      method = "test_method"
      params = %{"param1" => "value1", "param2" => 42}
      id = "test-id-123"

      request = Formatter.create_request(method, params, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == method
      assert request["params"] == params
      assert request["id"] == id
    end

    test "creates a valid request without params" do
      method = "test_method"
      id = "test-id-123"

      request = Formatter.create_request(method, nil, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == method
      assert request["id"] == id
      refute Map.has_key?(request, "params")
    end

    test "creates a valid request with generated id" do
      method = "test_method"
      params = %{"param1" => "value1"}

      request = Formatter.create_request(method, params)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == method
      assert request["params"] == params
      assert is_binary(request["id"])
    end
  end

  describe "create_notification/2" do
    test "creates a valid notification with params" do
      method = "test_notification"
      params = %{"event" => "something_happened"}

      notification = Formatter.create_notification(method, params)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == method
      assert notification["params"] == params
      refute Map.has_key?(notification, "id")
    end

    test "creates a valid notification without params" do
      method = "test_notification"

      notification = Formatter.create_notification(method)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == method
      refute Map.has_key?(notification, "params")
      refute Map.has_key?(notification, "id")
    end
  end

  describe "create_success_response/2" do
    test "creates a valid success response with result" do
      id = "test-id-123"
      result = %{"data" => "some_data", "more" => [1, 2, 3]}

      response = Formatter.create_success_response(id, result)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == id
      assert response["result"] == result
      refute Map.has_key?(response, "error")
    end

    test "creates a valid success response with empty result" do
      id = "test-id-123"

      response = Formatter.create_success_response(id)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == id
      assert response["result"] == %{}
      refute Map.has_key?(response, "error")
    end
  end

  describe "create_error_response/4" do
    test "creates a valid error response with data" do
      id = "test-id-123"
      code = -32_000
      message = "Server error"
      data = %{"details" => "Something went wrong", "line" => 42}

      response = Formatter.create_error_response(id, code, message, data)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == id
      assert response["error"]["code"] == code
      assert response["error"]["message"] == message
      assert response["error"]["data"] == data
      refute Map.has_key?(response, "result")
    end

    test "creates a valid error response without data" do
      id = "test-id-123"
      code = -32_600
      message = "Invalid Request"

      response = Formatter.create_error_response(id, code, message)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == id
      assert response["error"]["code"] == code
      assert response["error"]["message"] == message
      refute Map.has_key?(response["error"], "data")
      refute Map.has_key?(response, "result")
    end

    test "creates a valid error response with null id" do
      code = -32_700
      message = "Parse error"

      response = Formatter.create_error_response(nil, code, message)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == nil
      assert response["error"]["code"] == code
      assert response["error"]["message"] == message
    end
  end

  describe "encode/1" do
    test "correctly encodes a message to JSON with newline" do
      message = %{"jsonrpc" => "2.0", "method" => "test", "id" => 1}
      encoded = Formatter.encode(message)

      assert is_binary(encoded)
      assert String.ends_with?(encoded, "\n")
      assert Jason.decode!(String.trim_trailing(encoded, "\n")) == message
    end
  end

  describe "initialize_request/5" do
    test "creates a valid initialize request with defaults" do
      protocol_version = "2024-11-05"
      client_name = "Test Client"
      client_version = "1.0.0"

      request = Formatter.initialize_request(protocol_version, client_name, client_version)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "initialize"
      assert is_binary(request["id"])

      params = request["params"]
      assert params["protocolVersion"] == protocol_version
      assert params["clientInfo"]["name"] == client_name
      assert params["clientInfo"]["version"] == client_version
      assert params["capabilities"]["roots"]["listChanged"] == true
      assert Map.has_key?(params["capabilities"], "sampling")
    end

    test "creates a valid initialize request with custom capabilities" do
      protocol_version = "2024-11-05"
      client_name = "Test Client"
      client_version = "1.0.0"

      capabilities = %{
        "experimental" => %{"feature" => true},
        "roots" => %{"listChanged" => false}
      }

      id = "init-123"

      request =
        Formatter.initialize_request(
          protocol_version,
          client_name,
          client_version,
          capabilities,
          id
        )

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "initialize"
      assert request["id"] == id

      params = request["params"]
      assert params["protocolVersion"] == protocol_version
      assert params["clientInfo"]["name"] == client_name
      assert params["clientInfo"]["version"] == client_version
      assert params["capabilities"]["experimental"]["feature"] == true
      assert params["capabilities"]["roots"]["listChanged"] == false
    end
  end

  describe "ping_request/1" do
    test "creates a valid ping request" do
      request = Formatter.ping_request()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "ping"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "creates a valid ping request with custom id" do
      id = "ping-123"
      request = Formatter.ping_request(id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "ping"
      assert request["id"] == id
      assert request["params"] == %{}
    end
  end

  describe "list_resources_request/2" do
    test "creates a valid list resources request without cursor" do
      request = Formatter.list_resources_request()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "creates a valid list resources request with cursor" do
      cursor = "next-page-token"
      id = "list-123"
      request = Formatter.list_resources_request(cursor, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/list"
      assert request["id"] == id
      assert request["params"]["cursor"] == cursor
    end
  end

  describe "read_resource_request/2" do
    test "creates a valid read resource request" do
      uri = "file:///path/to/resource.txt"
      request = Formatter.read_resource_request(uri)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/read"
      assert Map.has_key?(request, "id")
      assert request["params"]["uri"] == uri
    end

    test "creates a valid read resource request with custom id" do
      uri = "file:///path/to/resource.txt"
      id = "read-123"
      request = Formatter.read_resource_request(uri, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/read"
      assert request["id"] == id
      assert request["params"]["uri"] == uri
    end
  end

  describe "list_prompts_request/2" do
    test "creates a valid list prompts request without cursor" do
      request = Formatter.list_prompts_request()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "creates a valid list prompts request with cursor" do
      cursor = "next-page-token"
      id = "list-prompts-123"
      request = Formatter.list_prompts_request(cursor, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/list"
      assert request["id"] == id
      assert request["params"]["cursor"] == cursor
    end
  end

  describe "get_prompt_request/3" do
    test "creates a valid get prompt request without arguments" do
      name = "greeting_prompt"
      request = Formatter.get_prompt_request(name)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/get"
      assert Map.has_key?(request, "id")
      assert request["params"]["name"] == name
      refute Map.has_key?(request["params"], "arguments")
    end

    test "creates a valid get prompt request with arguments" do
      name = "greeting_prompt"
      arguments = %{"name" => "John", "formal" => true}
      id = "get-prompt-123"
      request = Formatter.get_prompt_request(name, arguments, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/get"
      assert request["id"] == id
      assert request["params"]["name"] == name
      assert request["params"]["arguments"] == arguments
    end
  end

  describe "list_tools_request/2" do
    test "creates a valid list tools request without cursor" do
      request = Formatter.list_tools_request()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "creates a valid list tools request with cursor" do
      cursor = "next-page-token"
      id = "list-tools-123"
      request = Formatter.list_tools_request(cursor, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert request["id"] == id
      assert request["params"]["cursor"] == cursor
    end
  end

  describe "call_tool_request/3" do
    test "creates a valid call tool request without arguments" do
      name = "calculator"
      request = Formatter.call_tool_request(name)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/call"
      assert Map.has_key?(request, "id")
      assert request["params"]["name"] == name
      refute Map.has_key?(request["params"], "arguments")
    end

    test "creates a valid call tool request with arguments" do
      name = "calculator"
      arguments = %{"operation" => "add", "a" => 5, "b" => 3}
      id = "call-tool-123"
      request = Formatter.call_tool_request(name, arguments, id)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/call"
      assert request["id"] == id
      assert request["params"]["name"] == name
      assert request["params"]["arguments"] == arguments
    end
  end

  describe "initialized_notification/0" do
    test "creates a valid initialized notification" do
      notification = Formatter.initialized_notification()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/initialized"
      refute Map.has_key?(notification, "id")
      refute Map.has_key?(notification, "params")
    end
  end

  describe "roots_list_changed_notification/0" do
    test "creates a valid roots list changed notification" do
      notification = Formatter.roots_list_changed_notification()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/roots/list_changed"
      refute Map.has_key?(notification, "id")
      refute Map.has_key?(notification, "params")
    end
  end

  describe "cancelled_notification/2" do
    test "creates a valid cancelled notification without reason" do
      request_id = "req-123"
      notification = Formatter.cancelled_notification(request_id)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/cancelled"
      refute Map.has_key?(notification, "id")
      assert notification["params"]["requestId"] == request_id
      refute Map.has_key?(notification["params"], "reason")
    end

    test "creates a valid cancelled notification with reason" do
      request_id = "req-123"
      reason = "Operation timed out"
      notification = Formatter.cancelled_notification(request_id, reason)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/cancelled"
      refute Map.has_key?(notification, "id")
      assert notification["params"]["requestId"] == request_id
      assert notification["params"]["reason"] == reason
    end
  end
end
