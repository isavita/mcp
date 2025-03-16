defmodule MCPTest do
  use ExUnit.Case, async: false
  doctest MCP

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  describe "version/0" do
    test "returns a string representation of the version" do
      version = MCP.version()
      assert is_binary(version)
      # Check for semantic version format (x.y.z)
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, version)
    end
  end

  describe "debug mode functions" do
    setup do
      # Store original debug setting to restore after tests
      original_debug = Application.get_env(:mcp, :debug)

      # Clean up after tests
      on_exit(fn ->
        if is_nil(original_debug) do
          Application.delete_env(:mcp, :debug)
        else
          Application.put_env(:mcp, :debug, original_debug)
        end
      end)

      :ok
    end

    test "enable_debug/0 sets debug mode to true" do
      MCP.enable_debug()
      assert Application.get_env(:mcp, :debug) == true
    end

    test "disable_debug/0 sets debug mode to false" do
      MCP.disable_debug()
      assert Application.get_env(:mcp, :debug) == false
    end

    test "debug_enabled?/0 returns current debug mode status" do
      MCP.enable_debug()
      assert MCP.debug_enabled?() == true

      MCP.disable_debug()
      assert MCP.debug_enabled?() == false
    end

    test "debug_enabled?/0 returns false by default" do
      # Clean the setting to test default behavior
      Application.delete_env(:mcp, :debug)
      assert MCP.debug_enabled?() == false
    end
  end

  describe "start_client/1" do
    test "starts a client with default options" do
      # Use direct transport for testing to avoid external dependencies
      original_transport = Application.get_env(:mcp, :default_transport)
      Application.put_env(:mcp, :default_transport, MCP.Test.DirectTransport)

      try do
        # Start a client
        assert {:ok, client} = MCP.start_client()
        assert is_pid(client)
        assert Process.alive?(client)

        # Clean up
        MCP.Client.close(client)
      after
        # Restore original setting
        if is_nil(original_transport) do
          Application.delete_env(:mcp, :default_transport)
        else
          Application.put_env(:mcp, :default_transport, original_transport)
        end
      end
    end

    test "passes options to client" do
      # Mock MCP.Client.start_link to verify options are passed through
      expect_opts = [debug_mode: true, custom_option: "value"]

      # Use meck to replace the function temporarily
      :meck.new(MCP.Client, [:passthrough])

      :meck.expect(MCP.Client, :start_link, fn opts ->
        # Verify options match what we expect
        assert Keyword.get(opts, :debug_mode) == true
        assert Keyword.get(opts, :custom_option) == "value"
        # Return a mock PID
        {:ok, spawn(fn -> :timer.sleep(100) end)}
      end)

      try do
        # Call the function with our test options
        {:ok, _pid} = MCP.start_client(expect_opts)

        # Verify our mocked function was called
        assert :meck.validate(MCP.Client)
      after
        # Clean up the mock
        :meck.unload(MCP.Client)
      end
    end
  end
end
