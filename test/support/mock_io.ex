defmodule MCP.Test.MockIO do
  @moduledoc """
  Mock IO module for testing the STDIO transport.

  This module simulates stdin/stdout operations for testing purposes.
  """

  use GenServer

  # Client API

  @doc """
  Starts the MockIO server.

  ## Options
  No options are required but this function accepts a keyword list
  to be compatible with standard supervision patterns.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  Simulates binread from a device. For testing only.

  In normal operation, we simulate input using the
  `MCP.Transport.Stdio.simulate_input/2` function instead.
  """
  def binread(_device, :line) do
    # Not used directly in tests since we simulate input via
    # MCP.Transport.Stdio.simulate_input/2
    :eof
  end

  @doc """
  Records output that would normally go to stdio.
  """
  def binwrite(_device, data) do
    GenServer.cast(__MODULE__, {:output, data})
    :ok
  end

  @doc """
  Returns all collected output as a single string.
  """
  def get_output do
    GenServer.call(__MODULE__, :get_output)
  end

  @doc """
  Clears all collected output.
  """
  def clear_output do
    GenServer.call(__MODULE__, :clear_output)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_) do
    {:ok, []}
  end

  @impl GenServer
  def handle_cast({:output, data}, state) do
    {:noreply, [data | state]}
  end

  @impl GenServer
  def handle_call(:get_output, _from, state) do
    output = state |> Enum.reverse() |> Enum.join("")
    {:reply, output, state}
  end

  @impl GenServer
  def handle_call(:clear_output, _from, _state) do
    {:reply, :ok, []}
  end
end
