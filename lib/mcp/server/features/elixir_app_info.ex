defmodule MCP.Server.Features.ElixirAppInfo do
  @moduledoc """
  MCP feature module providing tools to inspect the running Elixir/Erlang application.
  """
  require Logger

  @type tool_definition :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          # Return map for structured data
          handler: (map(), map() -> map())
        }

  @doc """
  Returns a list of tool definitions provided by this module.
  """
  @spec mcp_tools() :: list(tool_definition())
  def mcp_tools do
    [
      %{
        name: "get_erlang_memory",
        description:
          "Gets current Erlang VM memory usage details (total, processes, atom, binary, ets, code).",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        },
        handler: &get_erlang_memory/2
      },
      %{
        name: "get_process_count",
        description: "Gets the current number of running Erlang processes in the VM.",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        },
        handler: &get_process_count/2
      },
      %{
        name: "get_scheduler_info",
        description:
          "Gets information about BEAM schedulers (online count and approximate utilization if :cpu_sup is available).",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        },
        handler: &get_scheduler_info/2
      },
      %{
        name: "list_loaded_applications",
        description:
          "Lists the names, versions, and descriptions of all loaded OTP applications.",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        },
        handler: &list_loaded_applications/2
      }
    ]
  end

  # --- Tool Handlers ---

  @doc false
  def get_erlang_memory(_exchange_context, _args) do
    # Returns [{type, bytes}]
    memory_data = :erlang.memory()

    # Convert to a map with formatted byte values
    formatted_memory =
      Enum.into(memory_data, %{}, fn {type, bytes} ->
        {Atom.to_string(type), format_bytes(bytes)}
      end)

    # Return as a single text content block for now, or structure further if needed
    [%{"type" => "text", "text" => inspect(formatted_memory)}]
  end

  @doc false
  def get_process_count(_exchange_context, _args) do
    count = :erlang.system_info(:process_count)
    [%{"type" => "text", "text" => "Process Count: #{count}"}]
  end

  @doc false
  def get_scheduler_info(_exchange_context, _args) do
    online = :erlang.system_info(:schedulers_online)

    utilization_info =
      try do
        # :cpu_sup might not be running or available
        # Returns [{SchedulerId, UtilizationPercent}]
        util_list = :cpu_sup.util()

        formatted_util =
          Enum.map(util_list, fn {id, util} -> %{"id" => id, "utilization_percent" => util} end)

        %{"utilization_percent_per_scheduler" => formatted_util}
      rescue
        UndefinedFunctionError ->
          %{"utilization_error" => ":cpu_sup not available or function :util/0 undefined."}

        other_error ->
          %{"utilization_error" => "Error fetching utilization: #{inspect(other_error)}"}
      catch
        # Handles exits if cpu_sup isn't started
        :exit, reason ->
          %{
            "utilization_error" =>
              "Could not get utilization (:cpu_sup exited?): #{inspect(reason)}"
          }
      end

    result_map = Map.merge(%{"schedulers_online" => online}, utilization_info)

    [%{"type" => "text", "text" => inspect(result_map)}]
  end

  @doc false
  def list_loaded_applications(_exchange_context, _args) do
    # Returns [{app, desc, vsn}]
    apps = Application.loaded_applications()

    formatted_apps =
      Enum.map(apps, fn {app, desc, vsn} ->
        %{
          "name" => Atom.to_string(app),
          # Ensure it's a string
          "description" => List.to_string(desc),
          # Ensure it's a string
          "version" => List.to_string(vsn)
        }
      end)

    # Return as structured data within a text block (or could be custom JSON type if client supports)
    [%{"type" => "text", "text" => inspect(%{"loaded_applications" => formatted_apps})}]
  end

  # --- Helper Functions ---
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MiB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GiB"
end
