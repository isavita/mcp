defmodule MCP.Server.Transport.SSE.Plug do
  @moduledoc """
  Plug handling HTTP requests for the MCP Server SSE Transport.

  - Handles GET requests to establish SSE streams.
  - Handles POST requests to receive client messages.
  - Interacts with the MCP.Server.Transport.SSE GenServer.
  """
  import Plug.Conn
  require Logger

  alias MCP.Protocol.Formatter

  def init(opts) do
    # opts should contain :path and :transport_pid
    opts
  end

  def call(conn, opts) do
    mcp_path = Keyword.fetch!(opts, :path)
    transport_pid = Keyword.fetch!(opts, :transport_pid)

    if conn.request_path == mcp_path do
      # Check if transport process is alive
      if Process.alive?(transport_pid) do
        handle_mcp_request(conn, transport_pid)
      else
        Logger.error("SSE Plug: Transport process #{inspect(transport_pid)} is not alive.")
        send_resp(conn, 503, "Service Unavailable (Transport Down)")
      end
    else
      # Not our path, 404
      send_resp(conn, 404, "Not Found")
    end
  end

  defp handle_mcp_request(conn, transport_pid) do
    case conn.method do
      "GET" -> handle_get_sse(conn, transport_pid)
      "POST" -> handle_post_message(conn, transport_pid)
      _ -> send_resp(conn, 405, "Method Not Allowed")
    end
  end

  # Handle GET: Establish SSE stream
  defp handle_get_sse(conn, transport_pid) do
    # Define conn_id in the outer scope
    conn_id = generate_conn_id()
    Logger.debug("SSE Plug: GET request, establishing SSE stream #{conn_id}")

    try do
      # Register connection with the transport GenServer
      case GenServer.call(transport_pid, {:client_connected, conn_id, self()}, 10000) do
        :ok ->
          # Send SSE headers and initial keep-alive comment
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

          {:ok, conn} = chunk(conn, ": connected\n\n")

          # Enter loop to wait for messages from transport to send to client
          # Pass the original conn_id
          sse_loop(conn, transport_pid, conn_id)

        {:error, reason} ->
          Logger.error("SSE Plug: Failed to register connection #{conn_id}: #{inspect(reason)}")
          send_resp(conn, 500, "Internal Server Error (Connection Registration Failed)")

        # Handles timeout case from call
        other ->
          Logger.error(
            "SSE Plug: Timeout or unexpected reply registering connection #{conn_id}: #{inspect(other)}"
          )

          send_resp(conn, 503, "Service Unavailable (Timeout Registering)")
      end
    rescue
      # Now conn_id is in scope here
      e ->
        Logger.error("SSE Plug: Error during GET handling for #{conn_id}: #{inspect(e)}")
        # Ensure connection is cleaned up if registration happened before error
        _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
        reraise e, System.stacktrace()
    end
  end

  # Handle POST: Receive message from client
  defp handle_post_message(conn, transport_pid) do
    # Use a temporary ID for logging/correlation during POST handling
    conn_id = generate_conn_id()
    Logger.debug("SSE Plug: POST request from #{conn_id}")

    # Read body
    case read_body(conn) do
      {:ok, body, conn} when is_binary(body) and byte_size(body) > 0 ->
        # Forward message to transport GenServer
        case GenServer.call(transport_pid, {:incoming_message, conn_id, body}, 10000) do
          :ok ->
            # Send 202 Accepted for notifications/responses
            # TODO: Adapt this based on Streamable HTTP spec for requests needing responses
            # For now, always send 202 as we don't handle server->client responses here yet
            send_resp(conn, 202, "")

          {:error, reason} ->
            Logger.error(
              "SSE Plug: Transport failed to handle incoming message from #{conn_id}: #{inspect(reason)}"
            )

            send_resp(conn, 500, "Internal Server Error (Message Handling Failed)")

          # Handles timeout
          other ->
            Logger.error(
              "SSE Plug: Timeout or unexpected reply handling incoming message from #{conn_id}: #{inspect(other)}"
            )

            send_resp(conn, 503, "Service Unavailable (Timeout Handling Message)")
        end

      {:ok, "", conn} ->
        Logger.warning("SSE Plug: Received empty POST body from #{conn_id}")
        send_resp(conn, 400, "Bad Request (Empty Body)")

      {:error, :timeout} ->
        Logger.error("SSE Plug: Timeout reading POST body from #{conn_id}")
        # Conn is likely already closed here, attempt might fail
        try do
          send_resp(conn, 408, "Request Timeout")
        rescue
          _ -> :ok
        end

        # Indicate error
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("SSE Plug: Error reading POST body from #{conn_id}: #{inspect(reason)}")
        send_resp(conn, 400, "Bad Request (Body Read Error)")
    end
  end

  # SSE sending loop
  defp sse_loop(conn, transport_pid, conn_id) do
    receive do
      # Message from transport GenServer to send to this client
      {:send_sse_event, message} ->
        try do
          # Format as SSE data event
          # Adds newline
          encoded_message = Formatter.encode(message)
          # Add extra newline for SSE format
          sse_data = "data: #{encoded_message}\n"
          {:ok, conn} = chunk(conn, sse_data)
          # Continue looping
          sse_loop(conn, transport_pid, conn_id)
        catch
          # Handle connection closed errors during chunk sending
          :error, %{__exception__: true, term: {%Plug.Conn.AlreadySentError{}, _}} ->
            Logger.debug("SSE Plug: Connection #{conn_id} closed (AlreadySentError).")
            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop
            :ok

          :error, :closed ->
            Logger.debug("SSE Plug: Connection #{conn_id} closed.")
            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop
            :ok

          kind, reason ->
            stacktrace = System.stacktrace()

            Logger.error(
              "SSE Plug: Error sending chunk to #{conn_id}: #{inspect(kind)}, #{inspect(reason)}\n#{inspect(stacktrace)}"
            )

            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop on error
            :ok
        end

      # Other messages (e.g., shutdown signal) could be handled here
      _other ->
        sse_loop(conn, transport_pid, conn_id)
    after
      # Send keep-alive comment every 25 seconds
      25_000 ->
        try do
          {:ok, conn} = chunk(conn, ": keepalive\n\n")
          sse_loop(conn, transport_pid, conn_id)
        catch
          # Handle connection closed errors during chunk sending
          :error, %{__exception__: true, term: {%Plug.Conn.AlreadySentError{}, _}} ->
            Logger.debug(
              "SSE Plug: Connection #{conn_id} closed (AlreadySentError on keepalive)."
            )

            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop
            :ok

          :error, :closed ->
            Logger.debug("SSE Plug: Connection #{conn_id} closed (on keepalive).")
            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop
            :ok

          kind, reason ->
            stacktrace = System.stacktrace()

            Logger.error(
              "SSE Plug: Error sending keepalive to #{conn_id}: #{inspect(kind)}, #{inspect(reason)}\n#{inspect(stacktrace)}"
            )

            _ = GenServer.call(transport_pid, {:client_disconnected, conn_id}, 5000)
            # Exit loop on error
            :ok
        end
    end
  end

  defp generate_conn_id(), do: "mcp_conn_#{Base.encode16(:crypto.strong_rand_bytes(8))}"
end
