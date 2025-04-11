defmodule MCP.Server.Transport.SSETest do
  use ExUnit.Case, async: false
  require Logger

  # Use HTTPoison or Finch for actual HTTP client testing
  # For simplicity, this test focuses on the GenServer API and state.
  # Real integration tests would require an HTTP client.

  alias MCP.Server.Transport.SSE
  alias MCP.Protocol.Formatter

  # Use a different port
  @test_port 5001
  @test_path "/mcp-server-test"

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # Mock the main MCP.Server process
    mock_server_pid = spawn_link(fn -> mock_mcp_server(self()) end)

    start_opts = [
      port: @test_port,
      path: @test_path,
      server_pid: mock_server_pid,
      debug_mode: false
    ]

    {:ok, transport} = start_supervised({SSE, start_opts})
    {:ok, transport: transport, mock_server_pid: mock_server_pid}
  end

  describe "Server SSE Transport" do
    test "starts and registers with a server_pid", %{transport: transport} do
      assert is_pid(transport)
      assert Process.alive?(transport)
      # Check state if needed via get_state
      assert {:ok, state} = SSE.get_state(transport)
      assert state.port == @test_port
      assert state.path == @test_path
    end

    test "handles client connection/disconnection notifications", %{
      transport: transport,
      mock_server_pid: server_pid
    } do
      conn_id = "test-conn-1"
      # Mock plug process
      plug_pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Simulate Plug connecting
      :ok = GenServer.call(transport, {:client_connected, conn_id, plug_pid})
      assert_receive {:client_connected, ^transport, ^conn_id}, 1000

      assert {:ok, state} = SSE.get_state(transport)
      assert state.connection_count == 1

      # Simulate Plug disconnecting
      :ok = GenServer.call(transport, {:client_disconnected, conn_id})
      assert_receive {:client_disconnected, ^transport, ^conn_id}, 1000

      assert {:ok, state_after} = SSE.get_state(transport)
      assert state_after.connection_count == 0

      Process.exit(plug_pid, :kill)
    end

    test "forwards incoming messages to server_pid", %{
      transport: transport,
      mock_server_pid: server_pid
    } do
      conn_id = "test-conn-2"
      message = Formatter.ping_request("ping-from-client")
      raw_json = Jason.encode!(message)

      # Simulate Plug receiving POST
      :ok = GenServer.call(transport, {:incoming_message, conn_id, raw_json})

      # Assert the mock_server_pid received it
      assert_receive {:mcp_message, {^transport, ^conn_id, ^raw_json}}, 1000
    end

    test "sends outgoing messages to the correct plug process", %{transport: transport} do
      conn_id = "test-conn-3"
      # Mock plug process that sends received messages back to test process
      plug_pid = spawn_link(fn -> plug_message_loop(self()) end)
      # Monitor the plug process
      Process.monitor(plug_pid)

      # Register the mock plug process as a connection
      :ok = GenServer.call(transport, {:client_connected, conn_id, plug_pid})
      # Wait for server notification
      assert_receive {:client_connected, _, _}, 500

      # Send a message via the transport to this connection
      response = Formatter.create_success_response("req-1", %{"result" => "ok"})
      :ok = SSE.send_message(transport, conn_id, response)

      # Assert the mock plug process received the message
      assert_receive {:send_sse_event, ^response}, 1000

      # Clean up
      Process.exit(plug_pid, :kill)
      assert_receive {:DOWN, _, :process, ^plug_pid, _}, 500
      # Ensure cleanup in transport state
      :ok = GenServer.call(transport, {:client_disconnected, conn_id})
    end
  end

  # Mock MCP.Server process
  defp mock_mcp_server(test_pid) do
    receive do
      {:client_connected, transport_pid, conn_id} ->
        send(test_pid, {:client_connected, transport_pid, conn_id})
        mock_mcp_server(test_pid)

      {:client_disconnected, transport_pid, conn_id} ->
        send(test_pid, {:client_disconnected, transport_pid, conn_id})
        mock_mcp_server(test_pid)

      {:mcp_message, {transport_pid, conn_id, raw_json}} ->
        send(test_pid, {:mcp_message, {transport_pid, conn_id, raw_json}})
        mock_mcp_server(test_pid)
    after
      10000 -> Logger.warning("Mock MCP Server timed out")
    end
  end

  # Mock Plug process loop
  defp plug_message_loop(test_pid) do
    receive do
      {:send_sse_event, message} ->
        send(test_pid, {:send_sse_event, message})
        plug_message_loop(test_pid)
    after
      10000 -> Logger.warning("Mock Plug loop timed out")
    end
  end
end
