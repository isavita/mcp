defmodule MCP.Test.DirectTransport do
  @moduledoc """
  A special transport implementation for testing that directly connects
  components without going through actual IO or IPC.
  """

  use GenServer
  require Logger
  alias MCP.Protocol.Formatter

  @behaviour MCP.Transport.Behaviour

  # Client API

  @impl MCP.Transport.Behaviour
  def start_link(opts \\ []) do
    mock_server = Keyword.get(opts, :mock_server, true)
    GenServer.start_link(__MODULE__, %{mock_server: mock_server})
  end

  @impl MCP.Transport.Behaviour
  def send_message(pid, message) do
    GenServer.call(pid, {:send_message, message})
  end

  @impl MCP.Transport.Behaviour
  def register_handler(pid, handler_pid) do
    GenServer.call(pid, {:register_handler, handler_pid})
  end

  @impl MCP.Transport.Behaviour
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl MCP.Transport.Behaviour
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # GenServer callbacks

  @impl GenServer
  def init(%{mock_server: true}) do
    # Create an automatic mock server that responds to requests
    {:ok,
     %{
       handler: nil,
       mock_server: true
     }}
  end

  @impl GenServer
  def init(_) do
    # Just a transport with no automatic responses
    {:ok,
     %{
       handler: nil,
       mock_server: false
     }}
  end

  @impl GenServer
  def handle_call({:register_handler, handler_pid}, _from, state) do
    Process.monitor(handler_pid)
    {:reply, :ok, %{state | handler: handler_pid}}
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, %{mock_server: true, handler: handler} = state)
      when is_pid(handler) do
    # Log the message
    Logger.debug("DirectTransport received message: #{inspect(message)}")

    # If it's a request with an ID, generate a mock response
    if Map.has_key?(message, "method") && Map.has_key?(message, "id") do
      # Create a response based on the method
      response = create_mock_response(message)
      Logger.debug("DirectTransport sending response: #{inspect(response)}")

      # Send the response to the handler
      send(handler, {:mcp_message, response})
    end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(
        {:send_message, message},
        _from,
        %{mock_server: false, handler: handler} = state
      )
      when is_pid(handler) do
    # Just log the message, don't generate responses
    Logger.debug("DirectTransport sending message: #{inspect(message)}")
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:send_message, _message}, _from, state) do
    # No handler registered
    {:reply, {:error, :no_handler}, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{handler: pid} = state) do
    # Handler process died, remove it
    {:noreply, %{state | handler: nil}}
  end

  # Helper functions

  defp create_mock_response(%{"method" => "initialize", "id" => id}) do
    Formatter.create_success_response(id, %{
      "protocolVersion" => "2024-11-05",
      "serverInfo" => %{
        "name" => "MockServer",
        "version" => "1.0.0"
      },
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{
          "listChanged" => true
        }
      }
    })
  end

  defp create_mock_response(%{"method" => method, "id" => id}) do
    Formatter.create_success_response(id, %{
      "success" => true,
      "method" => method
    })
  end
end
