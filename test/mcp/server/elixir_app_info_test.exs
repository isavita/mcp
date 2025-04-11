defmodule MCP.Server.ElixirAppInfoTest do
  use ExUnit.Case, async: false
  require Logger

  alias MCP.Server
  alias MCP.Test.DirectTransport
  alias MCP.Protocol.Formatter

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {:ok, transport} = DirectTransport.start_link(mock_server: false)

    # Use the new feature module
    server_opts = [
      transport: DirectTransport,
      transport_opts: [],
      # Use the new module
      features: [MCP.Server.Features.ElixirAppInfo],
      debug_mode: false
    ]

    {:ok, server} = Server.start_link(server_opts)
    :ok = DirectTransport.register_handler(transport, server)

    {:ok, server: server, transport: transport}
  end

  # Helper process to receive messages from DirectTransport
  defp test_message_loop(test_pid) do
    receive do
      {:mcp_message, msg} ->
        send(test_pid, {:mcp_message, msg})
        test_message_loop(test_pid)
    after
      10000 -> Logger.warning("Test handler loop timed out")
    end
  end

  # --- Test Cases ---

  describe "Server Initialization and Basic Requests" do
    # Keep initialize and ping tests as they are fundamental

    test "handles initialize request", %{server: _server, transport: transport} do
      client_pid = self()
      test_handler = spawn_link(fn -> test_message_loop(client_pid) end)
      :ok = DirectTransport.register_handler(transport, test_handler)

      init_req = Formatter.initialize_request("2025-03-26", "TestClient", "0.1")
      :ok = DirectTransport.send_message(transport, init_req)

      assert_receive {:mcp_message, response}, 5000
      assert response["id"] == init_req["id"]
      assert response["result"]["protocolVersion"] == "2025-03-26"
      assert response["result"]["serverInfo"]["name"] == "Elixir MCP Server"
      assert response["result"]["capabilities"]["tools"]["listChanged"] == true
    end

    test "handles ping request", %{server: _server, transport: transport} do
      client_pid = self()
      test_handler = spawn_link(fn -> test_message_loop(client_pid) end)
      :ok = DirectTransport.register_handler(transport, test_handler)

      ping_req = Formatter.ping_request("ping-1")
      :ok = DirectTransport.send_message(transport, ping_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "ping-1"
      assert response["result"] == %{}
    end
  end

  describe "Elixir App Info Tool Handling" do
    # Helper to initialize connection for tool tests
    defp initialize_for_tools(transport) do
      client_pid = self()
      test_handler = spawn_link(fn -> test_message_loop(client_pid) end)
      :ok = DirectTransport.register_handler(transport, test_handler)
      init_req = Formatter.initialize_request("2025-03-26", "TestClient", "0.1")
      :ok = DirectTransport.send_message(transport, init_req)
      assert_receive {:mcp_message, _init_resp}, 1000
      :ok = DirectTransport.send_message(transport, Formatter.initialized_notification())
      :ok
    end

    test "handles tools/list request for Elixir tools", %{server: _server, transport: transport} do
      initialize_for_tools(transport)
      list_req = Formatter.list_tools_request("list-elixir-tools-1")
      :ok = DirectTransport.send_message(transport, list_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "list-elixir-tools-1"
      tools = response["result"]["tools"]
      assert is_list(tools)
      tool_names = Enum.map(tools, & &1["name"])
      assert "get_erlang_memory" in tool_names
      assert "get_process_count" in tool_names
      assert "get_scheduler_info" in tool_names
      assert "list_loaded_applications" in tool_names
    end

    test "handles tools/call request for get_erlang_memory", %{
      server: _server,
      transport: transport
    } do
      initialize_for_tools(transport)
      call_req = Formatter.call_tool_request("get_erlang_memory", %{}, "call-mem-1")
      :ok = DirectTransport.send_message(transport, call_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "call-mem-1"
      assert response["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      # Check if the text looks like the inspect output of the memory map
      assert String.contains?(text, "%{")
      assert String.contains?(text, "\"total\" =>")
      assert String.contains?(text, "\"processes\" =>")

      assert String.contains?(text, "KiB") or String.contains?(text, "MiB") or
               String.contains?(text, "GiB") or String.contains?(text, " B")
    end

    test "handles tools/call request for get_process_count", %{
      server: _server,
      transport: transport
    } do
      initialize_for_tools(transport)
      call_req = Formatter.call_tool_request("get_process_count", %{}, "call-proc-1")
      :ok = DirectTransport.send_message(transport, call_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "call-proc-1"
      assert response["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert Regex.match?(~r/Process Count: \d+/, text)
    end

    test "handles tools/call request for get_scheduler_info", %{
      server: _server,
      transport: transport
    } do
      initialize_for_tools(transport)
      call_req = Formatter.call_tool_request("get_scheduler_info", %{}, "call-sched-1")
      :ok = DirectTransport.send_message(transport, call_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "call-sched-1"
      assert response["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert String.contains?(text, "\"schedulers_online\" =>")
      # Utilization might error or succeed depending on env
      assert String.contains?(text, "\"utilization_percent_per_scheduler\" => [%{") or
               String.contains?(text, "\"utilization_error\" =>")
    end

    test "handles tools/call request for list_loaded_applications", %{
      server: _server,
      transport: transport
    } do
      initialize_for_tools(transport)
      call_req = Formatter.call_tool_request("list_loaded_applications", %{}, "call-apps-1")
      :ok = DirectTransport.send_message(transport, call_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "call-apps-1"
      assert response["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert String.contains?(text, "\"loaded_applications\" => [%{")
      # Elixir should always be loaded
      assert String.contains?(text, "\"name\" => \"elixir\"")
      # Our app
      assert String.contains?(text, "\"name\" => \"mcp\"")
    end

    # Keep the unknown tool test
    test "handles tools/call for unknown tool", %{server: _server, transport: transport} do
      initialize_for_tools(transport)
      call_req = Formatter.call_tool_request("unknown_tool", %{}, "call-unknown-1")
      :ok = DirectTransport.send_message(transport, call_req)

      assert_receive {:mcp_message, response}, 1000
      assert response["id"] == "call-unknown-1"
      assert response["error"]["code"] == -32601
    end
  end
end
