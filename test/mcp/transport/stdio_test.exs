defmodule MCP.Transport.StdioTest do
  use ExUnit.Case, async: false
  require Logger

  alias MCP.Transport.Stdio
  alias MCP.Protocol.Formatter

  # Set longer timeout for process communication
  @moduletag timeout: 5000

  # Define a command for a simple external process that echoes stdin to stdout
  # Using `/bin/cat` is standard on Unix-like systems (macOS, Linux).
  @test_command "/bin/cat"

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

    # Start supervised and raise if it fails during setup
    case start_supervised({Stdio, start_opts}) do
      {:ok, transport} ->
        # Create a test handler process (simulates the MCP.Client)
        test_pid = self()
        handler = spawn(fn -> message_handler(test_pid) end)

        # Register the handler immediately
        :ok = Stdio.register_handler(transport, handler)

        # Return test context using :ok tuple for setup success
        {:ok, transport: transport, handler: handler, test_name: test_name}

      {:error, reason} ->
        # Raise an error to fail the setup explicitly
        raise "Stdio transport failed to start in setup: #{inspect(reason)}"
    end
  end

  describe "start_link/1" do
    test "starts and returns a process when command is valid", %{transport: transport} do
      assert is_pid(transport)
      assert Process.alive?(transport)
      assert Port.info(GenServer.call(transport, :get_raw_port_for_test)) != nil
    end

    test "returns error if command option is missing" do
      assert_raise ArgumentError, ~r/:command option is required/, fn ->
        Stdio.start_link([])
      end
    end

    # FIX 1: Test that transport stops shortly after start with invalid command
    test "transport stops when command is invalid" do
      invalid_command = "/path/hopefully/does/not/exist/xyzabc123"
      # Start the transport directly (not supervised for this test)
      # and link it so we get EXIT signal
      {:ok, transport_pid} = Stdio.start_link(command: invalid_command)

      # Trap exits to receive the EXIT message instead of crashing
      Process.flag(:trap_exit, true)

      # Assert that the transport process exits with an external process error
      # The status code 127 is common for "command not found" from sh.
      assert_receive {:EXIT, ^transport_pid, {:external_process_exited, status}}, 1000
      # Check status is non-zero (e.g., 127)
      refute status == 0

      # Untrap exits
      Process.flag(:trap_exit, false)
    end

    test "can be started with a name", %{transport: transport, test_name: test_name} do
      assert Process.whereis(test_name) == transport
    end
  end

  describe "register_handler/2" do
    test "registers a handler process", %{transport: transport, handler: _handler} do
      assert {:ok, _state} = Stdio.get_state(transport)
      test = self()
      handler2 = spawn(fn -> message_handler(test) end)
      assert :ok = Stdio.register_handler(transport, handler2)
      Process.exit(handler2, :kill)
    end
  end

  describe "send_message/2" do
    test "encodes and sends a message to the external process", %{transport: transport} do
      message = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")
      assert :ok = Stdio.send_message(transport, message)
      expected_echo_response = Jason.decode!(Jason.encode!(message))
      assert_receive {:message_received, ^expected_echo_response}, 3000
    end

    # /mcp/test/mcp/transport/stdio_test.exs

    # ... other tests ...

    # Renamed test to reflect what's actually being tested
    test "raises Exit when sending if transport process has stopped", %{} do
      # Trap exits to prevent test process crashing when linked transport stops
      Process.flag(:trap_exit, true)

      {:ok, transport} = Stdio.start_link(command: "elixir -e ':ok'")

      # Wait long enough for the external process to exit AND the transport
      # GenServer to process the :exit_status and stop itself.
      # Should be enough
      Process.sleep(500)

      # Optional but good: Verify the transport process is actually dead
      refute Process.alive?(transport)

      message = Formatter.create_request("test", %{}, "req-3")

      # Assert that calling send_message now raises an Exit exception
      # because the GenServer process (`transport`) is dead.
      assert_raise Exit, fn ->
        Stdio.send_message(transport, message)
      end

      # Untrap exits at the end of the test
      Process.flag(:trap_exit, false)
    end
  end

  describe "message reception" do
    test "receives and forwards messages from external process to handler", %{
      transport: transport,
      handler: _handler
    } do
      request = Formatter.create_request("echo_test", %{"data" => 123}, "req-echo")
      assert :ok = Stdio.send_message(transport, request)
      expected_response = Jason.decode!(Jason.encode!(request))
      assert_receive {:message_received, received_message}, 3000
      assert received_message == expected_response
    end

    test "handles multiple messages sent quickly", %{transport: transport, handler: _handler} do
      request1 = Formatter.create_request("method1", %{"id" => 1}, "req-m1")
      request2 = Formatter.create_request("method2", %{"id" => 2}, "req-m2")
      assert :ok = Stdio.send_message(transport, request1)
      Process.sleep(20)
      assert :ok = Stdio.send_message(transport, request2)
      expected1 = Jason.decode!(Jason.encode!(request1))
      expected2 = Jason.decode!(Jason.encode!(request2))
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

      Process.monitor(temp_handler)
      assert :ok = Stdio.register_handler(transport, temp_handler)
      assert_receive :handler_finished
      assert_receive {:DOWN, _, :process, ^temp_handler, _}
      Process.sleep(50)
      new_handler = spawn(fn -> message_handler(test) end)
      assert :ok = Stdio.register_handler(transport, new_handler)
      Process.exit(new_handler, :kill)
    end

    # FIX 2: Trap exits and assert {:EXIT, ...} message
    test "transport stops when external process exits", %{} do
      # Trap exits in this test process
      Process.flag(:trap_exit, true)

      {:ok, temp_transport} = Stdio.start_link(command: "elixir -e ':ok'")
      # We are linked because we started it directly

      # Wait for the transport process to EXIT because its external process exited
      assert_receive {:EXIT, ^temp_transport, {:external_process_exited, 0}}, 3000

      # Untrap exits
      Process.flag(:trap_exit, false)
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
      10_000 ->
        Logger.error("Test message_handler timed out")
        :timeout
    end
  end
end
