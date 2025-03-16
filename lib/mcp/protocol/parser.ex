defmodule MCP.Protocol.Parser do
  @moduledoc """
  Handles parsing of raw input into MCP protocol messages.

  This module is responsible for converting raw JSON strings into properly
  structured and validated MCP protocol messages.
  """

  alias MCP.Protocol.Validator

  @doc """
  Parses raw input (typically a string) into a structured message.

  ## Parameters
    * `raw_input` - A binary (string) containing a JSON-RPC message

  ## Returns
    * `{:ok, message}` - Successfully parsed message
    * `{:error, reason}` - Error with reason
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(raw_input) when is_binary(raw_input) do
    with {:ok, decoded} <- Jason.decode(raw_input),
         {:ok, validated} <- validate_message(decoded) do
      {:ok, validated}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_decode_error, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Attempts to extract a complete message from a buffer that may contain
  partial or multiple messages.

  ## Parameters
    * `buffer` - A binary (string) buffer that may contain one or more messages

  ## Returns
    * `{:ok, message, rest}` - Successfully extracted message with remaining buffer
    * `{:incomplete, buffer}` - Buffer doesn't contain a complete message
    * `{:error, reason, rest}` - Error parsing with remaining buffer
  """
  @spec extract_message(binary()) ::
          {:ok, map(), binary()}
          | {:incomplete, binary()}
          | {:error, term(), binary()}
  def extract_message(buffer) when is_binary(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case parse(line) do
          {:ok, message} ->
            {:ok, message, rest}

          {:error, reason} ->
            {:error, reason, rest}
        end

      [_incomplete] ->
        {:incomplete, buffer}
    end
  end

  # Private functions

  defp validate_message(decoded) do
    cond do
      # If it has both 'method' and 'id', it's a request
      Map.has_key?(decoded, "method") and Map.has_key?(decoded, "id") ->
        Validator.validate_request(decoded)

      # If it has 'method' but no 'id', it's a notification
      Map.has_key?(decoded, "method") and not Map.has_key?(decoded, "id") ->
        Validator.validate_notification(decoded)

      # If it has 'id' and either 'result' or 'error', it's a response
      Map.has_key?(decoded, "id") and
          (Map.has_key?(decoded, "result") or Map.has_key?(decoded, "error")) ->
        Validator.validate_response(decoded)

      # Otherwise, we don't know what it is
      true ->
        {:error, "Unable to determine message type: #{inspect(decoded)}"}
    end
  end
end
