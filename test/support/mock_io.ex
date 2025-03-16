defmodule MCP.Test.MockIO do
  @moduledoc """
  Mock IO module for testing the STDIO transport.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  def binread(_device, :line) do
    :eof
  end

  def binwrite(_device, data) do
    # When something writes to stdout, distribute to registered transports
    case find_server() do
      {:ok, pid} -> GenServer.cast(pid, {:distribute, data})
      {:error, _} -> Logger.warning("MockIO: No process found to distribute message")
    end

    :ok
  end

  def get_output do
    case find_server() do
      {:ok, pid} -> GenServer.call(pid, :get_output)
      {:error, _} -> ""
    end
  end

  def clear_output do
    case find_server() do
      {:ok, pid} -> GenServer.call(pid, :clear_output)
      {:error, _} -> :ok
    end
  end

  def register_transport(transport_pid) do
    case find_server() do
      {:ok, pid} -> GenServer.call(pid, {:register_transport, transport_pid})
      {:error, _} -> :ok
    end
  end

  # GenServer callbacks

  @impl GenServer
  def init(_) do
    {:ok, %{output: [], transports: []}}
  end

  @impl GenServer
  def handle_cast({:distribute, data}, state) do
    # Log what's being sent
    Logger.debug("MockIO distributing: #{inspect(data)}")

    # Store in output for inspection
    updated_output = [data | state.output]

    # Forward to all registered transports
    for transport <- state.transports do
      if Process.alive?(transport) do
        send(transport, {:io_data, data})
      end
    end

    {:noreply, %{state | output: updated_output}}
  end

  @impl GenServer
  def handle_call({:register_transport, pid}, _from, state) do
    Logger.debug("MockIO registered transport: #{inspect(pid)}")
    # Add this transport if not already registered
    updated_transports =
      if Enum.member?(state.transports, pid) do
        state.transports
      else
        [pid | state.transports]
      end

    {:reply, :ok, %{state | transports: updated_transports}}
  end

  @impl GenServer
  def handle_call(:get_output, _from, state) do
    output = state.output |> Enum.reverse() |> Enum.join("")
    {:reply, output, state}
  end

  @impl GenServer
  def handle_call(:clear_output, _from, state) do
    {:reply, :ok, %{state | output: []}}
  end

  # Private functions

  # Try to find the server process, checking multiple places
  defp find_server do
    case Process.whereis(:mock_io_test) do
      nil ->
        # Try to find in the ExUnit supervisor
        case Process.whereis(MCP.Test.MockIO) do
          nil -> {:error, :not_found}
          pid -> {:ok, pid}
        end

      pid ->
        {:ok, pid}
    end
  end
end
