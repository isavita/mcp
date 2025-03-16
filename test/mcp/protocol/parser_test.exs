defmodule MCP.Protocol.ParserTest do
  use ExUnit.Case, async: true
  doctest MCP.Protocol.Parser

  alias MCP.Protocol.{Parser, Formatter}

  describe "parse/1" do
    test "successfully parses a valid request" do
      request = Formatter.create_request("test_method", %{"param" => "value"}, "req-123")
      json = Jason.encode!(request)

      assert {:ok, parsed} = Parser.parse(json)
      assert parsed["method"] == "test_method"
      assert parsed["params"]["param"] == "value"
      assert parsed["id"] == "req-123"
    end

    test "successfully parses a valid notification" do
      notification = Formatter.create_notification("test_notification", %{"event" => "something"})
      json = Jason.encode!(notification)

      assert {:ok, parsed} = Parser.parse(json)
      assert parsed["method"] == "test_notification"
      assert parsed["params"]["event"] == "something"
      refute Map.has_key?(parsed, "id")
    end

    test "successfully parses a valid response" do
      response = Formatter.create_success_response("resp-123", %{"data" => "result"})
      json = Jason.encode!(response)

      assert {:ok, parsed} = Parser.parse(json)
      assert parsed["id"] == "resp-123"
      assert parsed["result"]["data"] == "result"
    end

    test "successfully parses a valid error response" do
      error_response =
        Formatter.create_error_response("err-123", -32_000, "Server error", %{
          "detail" => "Something went wrong"
        })

      json = Jason.encode!(error_response)

      assert {:ok, parsed} = Parser.parse(json)
      assert parsed["id"] == "err-123"
      assert parsed["error"]["code"] == -32_000
      assert parsed["error"]["message"] == "Server error"
      assert parsed["error"]["data"]["detail"] == "Something went wrong"
    end

    test "returns error for invalid JSON" do
      invalid_json = "{invalid_json"

      assert {:error, {:json_decode_error, _}} = Parser.parse(invalid_json)
    end

    test "returns error for non-JSON-RPC message" do
      non_jsonrpc = Jason.encode!(%{"foo" => "bar"})

      assert {:error, message} = Parser.parse(non_jsonrpc)
      assert message =~ "Unable to determine message type"
    end

    test "returns error for JSON-RPC message with invalid structure" do
      # Missing jsonrpc version
      invalid = Jason.encode!(%{"method" => "test", "id" => 1})

      assert {:error, message} = Parser.parse(invalid)
      assert message =~ "Missing or invalid 'jsonrpc' field"
    end
  end

  describe "extract_message/1" do
    test "extracts a single complete message with newline" do
      request = Formatter.create_request("test_method", %{"param" => "value"}, "req-123")
      json = Jason.encode!(request)
      buffer = json <> "\n"

      assert {:ok, parsed, ""} = Parser.extract_message(buffer)
      assert parsed["method"] == "test_method"
      assert parsed["params"]["param"] == "value"
      assert parsed["id"] == "req-123"
    end

    test "extracts a message and returns rest of buffer" do
      request1 = Formatter.create_request("method1", %{}, "1")
      request2 = Formatter.create_request("method2", %{}, "2")

      json1 = Jason.encode!(request1)
      json2 = Jason.encode!(request2)

      buffer = json1 <> "\n" <> json2 <> "\n"

      assert {:ok, parsed, rest} = Parser.extract_message(buffer)
      assert parsed["method"] == "method1"
      assert parsed["id"] == "1"
      assert rest == json2 <> "\n"
    end

    test "returns incomplete when buffer doesn't contain a complete message" do
      request = Formatter.create_request("test_method", %{}, "1")
      partial = Jason.encode!(request)

      # No newline, so it's incomplete
      assert {:incomplete, ^partial} = Parser.extract_message(partial)
    end

    test "returns error with rest when message is invalid" do
      invalid_json = "{invalid_json\n"
      valid_json = Jason.encode!(Formatter.create_request("method", %{}, "1")) <> "\n"
      buffer = invalid_json <> valid_json

      assert {:error, _, rest} = Parser.extract_message(buffer)
      assert rest == valid_json
    end
  end
end
