defmodule MCP.Transport.SSETest do
  use ExUnit.Case, async: false
  require Logger

  alias MCP.Transport.SSE
  alias MCP.Protocol.Formatter

  # Set longer timeout for SSE communication
  @moduletag timeout: 10000

  setup do
    # Configure logger to reduce noise during tests
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # Use unique port for each test to avoid conflicts
    test_port = 4000 + System.unique_integer([:positive]) |> rem(1000) |> abs()

    # Start the transport with test settings
    start_opts = [
      port: test_port,
      path: "/mcp-test",
      debug_mode: Application.get_env(:mcp, :debug, true)
    ]

    # Start supervised to ensure cleanup
    case start_supervised({SSE, start_opts}) do
      {:ok, transport} ->
        # Create a test handler process (simulates the MCP.Client)
        test_pid = self()
        handler = spawn_link(fn -> message_handler(test_pid) end)

        # Register the handler immediately
        :ok = SSE.register_handler(transport, handler)

        # Return test context
        {:ok, transport: transport, handler: handler, opts: start_opts}

      {:error, reason} ->
        raise "SSE transport failed to start in setup: #{inspect(reason)}"
    end
  end

  describe "start_link/1" do
    test "starts and returns a process", %{transport: transport} do
      assert is_pid(transport)
      assert Process.alive?(transport)
    end

    test "can be configured with different port and path" do
      custom_port = 4999
      custom_path = "/custom-mcp"

      {:ok, custom_transport} = SSE.start_link(port: custom_port, path: custom_path)
      assert Process.alive?(custom_transport)
      assert {:ok, state} = SSE.get_state(custom_transport)
      assert state.port == custom_port
      assert state.path == custom_path

      SSE.close(custom_transport)
    end
  end

  describe "register_handler/2" do
    test "registers a handler process", %{transport: transport} do
      assert {:ok, state} = SSE.get_state(transport)
      assert state.has_handler == true
    end
  end

  describe "send_message/2" do
    test "accepts message for sending", %{transport: transport} do
      message = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")
      assert :ok = SSE.send_message(transport, message)
    end
  end

  # A simple integration test could be added here that actually connects
  # via HTTP to the server, but that would require an HTTP client library.
  # For now, we'll just test the transport's API.

  # Helper function for the test handler process
  defp message_handler(test_process) do
    receive do
      {:mcp_message, message} ->
        send(test_process, {:message_received, message})
        # Loop to handle multiple messages
        message_handler(test_process)
    after
      60_000 ->
        Logger.error("Test message_handler timed out")
        :timeout
    end
  end
end
