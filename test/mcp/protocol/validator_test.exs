defmodule MCP.Protocol.ValidatorTest do
  use ExUnit.Case, async: true
  doctest MCP.Protocol.Validator

  alias MCP.Protocol.Validator

  describe "validate_response/1" do
    test "validates a successful response" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"value" => "success"}
      }

      assert {:ok, ^response} = Validator.validate_response(response)
    end

    test "validates an error response" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => "abc",
        "error" => %{
          "code" => -32_000,
          "message" => "Server error"
        }
      }

      assert {:ok, ^response} = Validator.validate_response(response)
    end

    test "rejects a response with missing jsonrpc version" do
      response = %{
        "id" => 1,
        "result" => %{"value" => "success"}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "Missing or invalid 'jsonrpc' field"
    end

    test "rejects a response with wrong jsonrpc version" do
      response = %{
        "jsonrpc" => "1.0",
        "id" => 1,
        "result" => %{"value" => "success"}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "Missing or invalid 'jsonrpc' field"
    end

    test "rejects a response with missing id" do
      response = %{
        "jsonrpc" => "2.0",
        "result" => %{"value" => "success"}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "Missing or invalid 'id' field"
    end

    test "rejects a response with nil id" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "result" => %{"value" => "success"}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "Missing or invalid 'id' field"
    end

    test "rejects a response with non-string or non-number id" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => true,
        "result" => %{"value" => "success"}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "Missing or invalid 'id' field"
    end

    test "rejects a response with neither result nor error" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "must contain either a valid 'result' or 'error' object"
    end

    test "rejects a response with incomplete error object" do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        # Missing message
        "error" => %{"code" => -32_000}
      }

      assert {:error, error} = Validator.validate_response(response)
      assert error =~ "must contain either a valid 'result' or 'error' object"
    end

    test "rejects a non-map input" do
      assert {:error, error} = Validator.validate_response("not a map")
      assert error =~ "Response is not a map"
    end
  end

  describe "validate_request/1" do
    test "validates a request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "test_method",
        "params" => %{"param1" => "value1"}
      }

      assert {:ok, ^request} = Validator.validate_request(request)
    end

    test "validates a request without params" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "abc",
        "method" => "test_method"
      }

      assert {:ok, ^request} = Validator.validate_request(request)
    end

    test "rejects a request with missing jsonrpc version" do
      request = %{
        "id" => 1,
        "method" => "test_method"
      }

      assert {:error, error} = Validator.validate_request(request)
      assert error =~ "Missing or invalid 'jsonrpc' field"
    end

    test "rejects a request with missing id" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "test_method"
      }

      assert {:error, error} = Validator.validate_request(request)
      assert error =~ "Missing or invalid 'id' field"
    end

    test "rejects a request with missing method" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1
      }

      assert {:error, error} = Validator.validate_request(request)
      assert error =~ "Missing or invalid 'method' field"
    end

    test "rejects a request with empty method" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => ""
      }

      assert {:error, error} = Validator.validate_request(request)
      assert error =~ "Missing or invalid 'method' field"
    end

    test "rejects a request with nil method" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => nil
      }

      assert {:error, error} = Validator.validate_request(request)
      assert error =~ "Missing or invalid 'method' field"
    end
  end

  describe "validate_notification/1" do
    test "validates a notification" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "test_notification",
        "params" => %{"param1" => "value1"}
      }

      assert {:ok, ^notification} = Validator.validate_notification(notification)
    end

    test "validates a notification without params" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "test_notification"
      }

      assert {:ok, ^notification} = Validator.validate_notification(notification)
    end

    test "rejects a notification with an id" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "test_notification",
        "id" => 1
      }

      assert {:error, error} = Validator.validate_notification(notification)
      assert error =~ "Notifications must not contain an 'id' field"
    end

    test "rejects a notification with missing jsonrpc version" do
      notification = %{
        "method" => "test_notification"
      }

      assert {:error, error} = Validator.validate_notification(notification)
      assert error =~ "Missing or invalid 'jsonrpc' field"
    end
  end
end
