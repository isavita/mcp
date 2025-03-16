defmodule MCP.ClientTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Protocol.Formatter
  alias MCP.Test.DirectTransport

  require Logger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # Start a direct transport with automatic mock responses
    {:ok, transport} = DirectTransport.start_link(mock_server: true)

    # Start client using our test transport
    {:ok, client} =
      Client.start_link(
        debug_mode: true,
        transport: DirectTransport,
        existing_transport: transport
      )

    # Return test context
    %{client: client, transport: transport}
  end

  describe "client-server communication" do
    test "notify/2 sends a notification without expecting a response", %{client: client} do
      # Send a notification
      notification = Formatter.create_notification("test_notification", %{"event" => "happened"})
      assert :ok = Client.notify(client, notification)
    end

    test "request/3 sends a request and receives a response", %{client: client} do
      # Create a test request
      request = Formatter.create_request("test_method", %{"param" => "value"})

      # Send it and wait for response
      assert {:ok, response} = Client.request(client, request, 1000)

      # Verify the response
      assert response["id"] == request["id"]
      assert response["result"]["method"] == "test_method"
      assert response["result"]["success"] == true
    end

    test "initialize/2 sends initialize request and processes response", %{client: client} do
      # Initialize the client
      assert {:ok, capabilities} = Client.initialize(client, timeout: 1000)

      # Verify the response
      assert capabilities["serverInfo"]["name"] == "MockServer"
      assert capabilities["protocolVersion"] == "2024-11-05"
    end

    test "ping/2 works", %{client: client} do
      # Send ping
      assert {:ok, :pong} = Client.ping(client, timeout: 1000)
    end

    test "list_resources/2 works", %{client: client} do
      # List resources
      assert {:ok, data} = Client.list_resources(client, timeout: 1000)

      # Verify the response
      assert data["success"] == true
      assert data["method"] == "resources/list"
    end

    test "read_resource/3 works", %{client: client} do
      # Read a resource
      assert {:ok, data} = Client.read_resource(client, "file:///test", timeout: 1000)

      # Verify the response
      assert data["success"] == true
      assert data["method"] == "resources/read"
    end
  end
end
