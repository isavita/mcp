defmodule MCP.Transport.StdioTest do
  use ExUnit.Case, async: false
  require Logger

  alias MCP.Transport.Stdio
  alias MCP.Protocol.Formatter
  alias MCP.Test.MockIO

  # Set longer timeout for process communication
  @moduletag timeout: 2000

  setup_all do
    # Start one MockIO for all tests to share
    {:ok, mock_io} = MockIO.start_link(name: MCP.Test.MockIO)

    on_exit(fn ->
      if Process.alive?(mock_io) do
        GenServer.stop(mock_io)
      end
    end)

    :ok
  end

  setup do
    # Configure logger to reduce noise
    previous_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # Clear any previous output
    MockIO.clear_output()

    # Use unique name for each test to avoid conflicts
    test_name = :"StdioTest#{:erlang.unique_integer([:positive])}"

    # Start a transport with the mock IO module
    {:ok, transport} =
      start_supervised(
        {Stdio,
         [
           name: test_name,
           debug_mode: false,
           io_module: MockIO
         ]}
      )

    # Create a test handler process
    test = self()
    handler = spawn(fn -> message_handler(test) end)

    # Return test context
    %{transport: transport, handler: handler, test_name: test_name}
  end

  describe "start_link/1" do
    test "starts and returns a process" do
      io_module = MockIO
      {:ok, pid} = Stdio.start_link(io_module: io_module)
      assert is_pid(pid)
      assert Process.alive?(pid)
      Stdio.close(pid)
    end

    test "can be started with a name", %{transport: transport, test_name: test_name} do
      assert Process.whereis(test_name) == transport
    end
  end

  describe "register_handler/2" do
    test "registers a handler process", %{transport: transport, handler: handler} do
      assert :ok = Stdio.register_handler(transport, handler)

      # Check internal state
      assert {:ok, state} = Stdio.get_state(transport)
      assert state.handler == handler
    end

    test "replaces existing handler", %{transport: transport} do
      test = self()
      handler1 = spawn(fn -> message_handler(test) end)
      handler2 = spawn(fn -> message_handler(test) end)

      assert :ok = Stdio.register_handler(transport, handler1)
      assert :ok = Stdio.register_handler(transport, handler2)

      # Check internal state
      assert {:ok, state} = Stdio.get_state(transport)
      assert state.handler == handler2
    end
  end

  describe "send_message/2" do
    test "encodes and sends a message", %{transport: transport} do
      # Prepare a message
      message = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")

      # Send it
      assert :ok = Stdio.send_message(transport, message)

      # Check what was sent to stdout
      output = MockIO.get_output()
      assert String.contains?(output, "test_method")
      assert String.contains?(output, "param")
      assert String.contains?(output, "value")
      assert String.ends_with?(output, "\n")
    end
  end

  describe "message reception" do
    test "receives and forwards messages to handler", %{transport: transport, handler: handler} do
      # Register handler
      :ok = Stdio.register_handler(transport, handler)

      # Send a request via simulated stdin
      request = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")
      json = Jason.encode!(request) <> "\n"
      Stdio.simulate_input(transport, json)

      # Check that handler forwarded it to us
      assert_receive {:message_received, message}
      assert message["method"] == "test_method"
      assert message["params"]["param"] == "value"
    end

    test "buffers partial messages until complete", %{transport: transport, handler: handler} do
      # Register handler
      :ok = Stdio.register_handler(transport, handler)

      # Send a partial message
      request = Formatter.create_request("test_method", %{"param" => "value"}, "req-1")
      json = Jason.encode!(request)

      # Split it into chunks
      half_point = div(String.length(json), 2)
      part1 = binary_part(json, 0, half_point)
      part2 = binary_part(json, half_point, String.length(json) - half_point) <> "\n"

      # Send first part
      Stdio.simulate_input(transport, part1)

      # We shouldn't get a message yet
      refute_receive {:message_received, _}, 100

      # Send second part
      Stdio.simulate_input(transport, part2)

      # Now we should get the complete message
      assert_receive {:message_received, message}
      assert message["method"] == "test_method"
    end

    test "handles multiple messages in a single chunk", %{transport: transport, handler: handler} do
      # Register handler
      :ok = Stdio.register_handler(transport, handler)

      # Create two messages
      request1 = Formatter.create_request("method1", %{"id" => 1}, "req-1")
      request2 = Formatter.create_request("method2", %{"id" => 2}, "req-2")

      # Combine them
      json = Jason.encode!(request1) <> "\n" <> Jason.encode!(request2) <> "\n"

      # Send both in one chunk
      Stdio.simulate_input(transport, json)

      # We should receive both messages
      assert_receive {:message_received, message1}
      assert message1["method"] == "method1"

      assert_receive {:message_received, message2}
      assert message2["method"] == "method2"
    end
  end

  describe "handler monitoring" do
    test "unregisters handler when it dies", %{transport: transport} do
      # Create a handler that will die
      temp_handler = spawn(fn -> :ok end)

      # Register it
      :ok = Stdio.register_handler(transport, temp_handler)

      # Wait for the handler to die and be unregistered
      Process.sleep(100)

      # Check that it was unregistered
      assert {:ok, state} = Stdio.get_state(transport)
      assert state.handler == nil
    end
  end

  # Helper function for the test handler process
  defp message_handler(test_process) do
    receive do
      {:mcp_message, message} ->
        send(test_process, {:message_received, message})
        message_handler(test_process)
    after
      # Prevent handler from running forever if test fails
      5000 -> :timeout
    end
  end
end
