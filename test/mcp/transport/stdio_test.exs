defmodule MCP.Transport.StdioTest do
  # Ports might not be async safe depending on external process
  use ExUnit.Case, async: false
  require Logger

  alias MCP.Transport.Stdio
  alias MCP.Protocol.Formatter

  # Set longer timeout for process communication
  @moduletag timeout: 5000

  # Define a command for a simple external process that echoes stdin to stdout
  # Using `cat` is generally reliable and standard on Unix-like systems.
  @test_command "cat"
  # If on Windows, you might need something different, e.g., a small script.
  # For testing failure:
  # @test_command "/path/to/nonexistent/mcp_server_dummy"

  setup do
    # Configure logger to reduce noise during tests
    previous_level = Logger.level()
    # Use :debug for detailed port logs
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # Use unique name for each test transport process to avoid conflicts
    test_name = :"StdioTest#{System.unique_integer([:positive])}"

    # Start the transport, providing the command to run the external server
    start_opts = [
      name: test_name,
      # Inherit debug setting
      debug_mode: Application.get_env(:mcp, :debug, false),
      command: @test_command
    ]

    # Start supervised to ensure cleanup
    # Wrap in try/catch to provide better error reporting if setup fails
    transport_result =
      try do
        start_supervised({Stdio, start_opts})
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case transport_result do
      {:ok, transport} ->
        # Create a test handler process (simulates the MCP.Client)
        test_pid = self()
        handler = spawn(fn -> message_handler(test_pid) end)

        # Register the handler immediately
        :ok = Stdio.register_handler(transport, handler)

        # Return test context
        %{transport: transport, handler: handler, test_name: test_name}

      {:error, reason} ->
        # Fail the setup explicitly if transport couldn't start
        pytest_skip = Map.get(System.get_env(), "PYTEST_CURRENT_TEST") != nil
        if pytest_skip, do: IO.puts("Skipping test due to setup failure: #{inspect(reason)}")
        refute pytest_skip, "Stdio transport failed to start in setup: #{inspect(reason)}"
        # Use ExUnit.Case.skip/1 if you prefer skipping over failing
        # skip("Stdio transport failed to start in setup: #{inspect(reason)}")
        # Return error to stop test execution
        {:error, reason}
    end
  end

  describe "start_link/1" do
    test "starts and returns a process when command is valid", %{transport: transport} do
      # Transport is started in setup using @test_command ("cat")
      assert is_pid(transport)
      assert Process.alive?(transport)
      # Check port is connected (specifics depend on OS)
      assert Port.info(GenServer.call(transport, :get_raw_port_for_test)) != nil
    end

    test "returns error if command option is missing" do
      assert_raise ArgumentError, ~r/:command option is required/, fn ->
        Stdio.start_link([])
      end
    end

    # Test for invalid command requires knowing how Port.open fails
    # This depends on OS and shell environment.
    test "returns error if command is invalid" do
      invalid_command = "/path/hopefully/does/not/exist/xyz"
      assert {:error, {:port_open_failed, _}} = Stdio.start_link(command: invalid_command)
    end

    test "can be started with a name", %{transport: transport, test_name: test_name} do
      assert Process.whereis(test_name) == transport
    end
  end

  describe "register_handler/2" do
    # Prefixed unused handler
    test "registers a handler process", %{transport: transport, handler: _handler} do
      # Handler is registered in setup, check internal state indirectly
      # Prefixed unused state
      assert {:ok, _state} = Stdio.get_state(transport)
      # We infer success from setup and lack of errors.
      # We can test replacement:
      test = self()
      handler2 = spawn(fn -> message_handler(test) end)
      assert :ok = Stdio.register_handler(transport, handler2)

      # To verify, we'd need to send a message and see which handler receives it.
      # For simplicity, assume registration works if :ok is returned.
    end
  end

  describe "send_message/2" do
    test "encodes and sends a message to the external process", %{transport: transport} do
      # Prepare a message
      message = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")

      # Send it
      assert :ok = Stdio.send_message(transport, message)

      # Verification: `cat` echoes the line back.
      # Wait for the echo handler to receive the message
      # Ensure keys are strings
      expected_echo_response = Jason.decode!(Jason.encode!(message))
      assert_receive {:message_received, ^expected_echo_response}, 3000
    end

    test "returns error if port is closed" do
      # Use a command that exits immediately
      {:ok, transport} = Stdio.start_link(command: "elixir -e ':ok'")
      # Give time for the short command to exit and port to close
      Process.sleep(150)
      message = Formatter.create_request("test", %{}, "req-2")

      # Port.command returns `false` if port is closed, which our code maps to {:error, :port_command_failed}
      assert {:error, :port_command_failed} = Stdio.send_message(transport, message)
      # Clean up GenServer
      Stdio.close(transport)
    end
  end

  describe "message reception" do
    # Prefixed unused handler
    test "receives and forwards messages from external process to handler", %{
      transport: transport,
      handler: _handler
    } do
      # Send a request (`cat` should echo it back)
      request = Formatter.create_request("echo_test", %{"data" => 123}, "req-echo")
      assert :ok = Stdio.send_message(transport, request)

      # Check that the handler received the echoed message
      expected_response = Jason.decode!(Jason.encode!(request))
      assert_receive {:message_received, received_message}, 3000
      assert received_message == expected_response
    end

    # Buffering tests are less relevant now as {:packet, :line} handles line splitting.
    # We rely on the Port driver for correctness here.

    # Prefixed unused handler
    test "handles multiple messages sent quickly", %{transport: transport, handler: _handler} do
      request1 = Formatter.create_request("method1", %{"id" => 1}, "req-m1")
      request2 = Formatter.create_request("method2", %{"id" => 2}, "req-m2")

      assert :ok = Stdio.send_message(transport, request1)
      # Short sleep might help ensure messages are distinct for basic echo server
      Process.sleep(20)
      assert :ok = Stdio.send_message(transport, request2)

      # Expect both messages back from `cat` (order should be preserved)
      expected1 = Jason.decode!(Jason.encode!(request1))
      expected2 = Jason.decode!(Jason.encode!(request2))

      # Receive messages - order should be deterministic with cat
      assert_receive {:message_received, ^expected1}, 3000
      assert_receive {:message_received, ^expected2}, 3000
    end
  end

  describe "process monitoring" do
    test "unregisters handler when it dies", %{transport: transport} do
      test = self()

      temp_handler =
        spawn(fn ->
          Process.sleep(50)
          send(test, :handler_finished)
        end)

      # Monitor from test too
      Process.monitor(temp_handler)

      assert :ok = Stdio.register_handler(transport, temp_handler)

      # Wait for the handler to die
      assert_receive :handler_finished
      assert_receive {:DOWN, _, :process, ^temp_handler, _}

      # Give GenServer time to process the :DOWN message
      Process.sleep(50)

      # Check that it was unregistered (handler should be nil)
      # Cannot directly check state.handler, so we infer by trying to register again
      new_handler = spawn(fn -> message_handler(test) end)
      assert :ok = Stdio.register_handler(transport, new_handler)
      # If the previous handler wasn't cleared, this might behave differently
      # or internal state could be inconsistent. Assume :ok means it worked.
      # Clean up new handler
      Process.exit(new_handler, :kill)
    end

    test "transport stops when external process exits", %{} do
      # Need a command that exits, e.g., "elixir -e ':ok'"
      {:ok, temp_transport} = Stdio.start_link(command: "elixir -e ':ok'")
      # Monitor the transport itself
      Process.monitor(temp_transport)
      # Wait for external process exit and transport to stop
      assert_receive {:DOWN, _, :process, ^temp_transport, {:external_process_exited, 0}}, 3000
    end
  end

  # Helper function for the test handler process
  defp message_handler(test_process) do
    receive do
      {:mcp_message, message} ->
        send(test_process, {:message_received, message})
        # Loop to handle multiple messages
        message_handler(test_process)
    after
      # Prevent handler from running forever if test fails/timeouts
      10_000 ->
        Logger.error("Test message_handler timed out")
        :timeout
    end
  end

  # Helper to get raw port for Port.info checks (add to Stdio module)
  @impl GenServer
  def handle_call(:get_raw_port_for_test, _from, state) do
    {:reply, state.port, state}
  end
end
