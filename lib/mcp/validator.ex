defmodule MCP.Validator do
  @moduledoc """
  Validates Model Context Protocol messages according to the JSON-RPC 2.0 specification.

  This module provides functions to validate JSON-RPC requests, responses, and
  notifications according to the MCP specification.
  """

  @doc """
  Validates a JSON-RPC response message.

  Returns:
  - {:ok, message} for valid messages
  - {:error, reason} for invalid messages
  """
  @spec validate_response(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_response(message) when is_map(message) do
    with :ok <- validate_jsonrpc_version(message),
         :ok <- validate_id_present(message),
         :ok <- validate_result_or_error(message) do
      {:ok, message}
    end
  end

  def validate_response(non_map) do
    {:error, "Response is not a map: #{inspect(non_map)}"}
  end

  @doc """
  Validates a request message according to JSON-RPC 2.0 specification.

  Returns:
  - {:ok, message} for valid messages
  - {:error, reason} for invalid messages
  """
  @spec validate_request(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_request(message) when is_map(message) do
    with :ok <- validate_jsonrpc_version(message),
         :ok <- validate_id_present(message),
         :ok <- validate_method_present(message) do
      {:ok, message}
    end
  end

  def validate_request(non_map) do
    {:error, "Request is not a map: #{inspect(non_map)}"}
  end

  @doc """
  Validates a notification message according to JSON-RPC 2.0 specification.

  Notifications are like requests but don't have an ID.

  Returns:
  - {:ok, message} for valid messages
  - {:error, reason} for invalid messages
  """
  @spec validate_notification(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_notification(message) when is_map(message) do
    with :ok <- validate_jsonrpc_version(message),
         :ok <- validate_method_present(message),
         :ok <- validate_no_id(message) do
      {:ok, message}
    end
  end

  def validate_notification(non_map) do
    {:error, "Notification is not a map: #{inspect(non_map)}"}
  end

  # Individual validation functions

  @spec validate_jsonrpc_version(map()) :: :ok | {:error, String.t()}
  defp validate_jsonrpc_version(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc_version(message) do
    {:error, "Missing or invalid 'jsonrpc' field (must be '2.0'): #{inspect(message)}"}
  end

  @spec validate_id_present(map()) :: :ok | {:error, String.t()}
  defp validate_id_present(%{"id" => id}) when is_binary(id) or is_number(id), do: :ok

  defp validate_id_present(message) do
    {:error, "Missing or invalid 'id' field: #{inspect(message)}"}
  end

  @spec validate_no_id(map()) :: :ok | {:error, String.t()}
  defp validate_no_id(%{"id" => _id}) do
    {:error, "Notifications must not contain an 'id' field"}
  end

  defp validate_no_id(_message), do: :ok

  @spec validate_method_present(map()) :: :ok | {:error, String.t()}
  defp validate_method_present(%{"method" => method})
       when is_binary(method) and method not in ["", nil] do
    :ok
  end

  defp validate_method_present(message) do
    {:error, "Missing or invalid 'method' field: #{inspect(message)}"}
  end

  @spec validate_result_or_error(map()) :: :ok | {:error, String.t()}
  defp validate_result_or_error(%{"result" => _}), do: :ok

  defp validate_result_or_error(%{"error" => %{"code" => code, "message" => msg}})
       when is_integer(code) and is_binary(msg) do
    :ok
  end

  defp validate_result_or_error(message) do
    {:error,
     "Message must contain either a valid 'result' or 'error' object: #{inspect(message)}"}
  end
end
