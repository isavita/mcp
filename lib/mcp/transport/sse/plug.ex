defmodule MCP.Transport.SSE.Plug do
  @moduledoc """
  A Plug for handling Server-Sent Events (SSE) connections for the MCP protocol.

  This plug handles both the SSE stream connection (GET requests) and
  incoming messages from clients (POST requests).
  """

  import Plug.Conn
  require Logger

  @doc """
  Initialize the plug with options
  """
  def init(opts) do
    opts
  end

  @doc """
  Handle the incoming connection
  """
  def call(conn, opts) do
    path = Keyword.get(opts, :path, "/mcp")
    transport = Keyword.get(opts, :transport)

    if conn.request_path == path do
      case conn.method do
        "GET" ->
          # Handle SSE connection
          handle_sse_connection(conn, transport)

        "POST" ->
          # Handle incoming messages
          handle_incoming_message(conn, transport)

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(405, "Method not allowed")
      end
    else
      # Not our path, pass through
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not found")
    end
  end

  # Handle SSE connection setup
  defp handle_sse_connection(conn, transport) do
    # Generate a unique ID for this connection
    connection_id = "conn_#{System.unique_integer([:positive])}"

    Logger.debug("New SSE connection: #{connection_id}")

    # Register this connection with the transport
    :ok = GenServer.call(transport, {:add_connection, connection_id, self()})

    # Set up SSE headers
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send a comment to keep the connection alive
    {:ok, conn} = chunk(conn, ": connected\n\n")

    # Start receiving messages from the transport
    receive_sse_messages(conn, transport, connection_id)
  end

  # Handle incoming messages from client
  defp handle_incoming_message(conn, transport) do
    # Read the request body
    {:ok, body, conn} = read_body(conn)

    # Forward the message to the transport
    GenServer.cast(transport, {:incoming_message, body})

    # Return a success response
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end

  # Receive messages from the transport and send them as SSE events
  defp receive_sse_messages(conn, transport, connection_id) do
    receive do
      {:sse_event, data} ->
        # Format and send SSE event
        try do
          {:ok, conn} = chunk(conn, "data: #{data}\n\n")
          receive_sse_messages(conn, transport, connection_id)
        catch
          :error, :closed ->
            Logger.debug("SSE connection closed: #{connection_id}")
            GenServer.cast(transport, {:remove_connection, connection_id})

          kind, reason ->
            Logger.error("SSE connection error: #{inspect(kind)}, #{inspect(reason)}")
            GenServer.cast(transport, {:remove_connection, connection_id})
        end

      {:sse_ping} ->
        # Send a keep-alive comment
        try do
          {:ok, conn} = chunk(conn, ": ping\n\n")
          receive_sse_messages(conn, transport, connection_id)
        catch
          :error, :closed ->
            Logger.debug("SSE connection closed: #{connection_id}")
            GenServer.cast(transport, {:remove_connection, connection_id})

          kind, reason ->
            Logger.error("SSE connection error: #{inspect(kind)}, #{inspect(reason)}")
            GenServer.cast(transport, {:remove_connection, connection_id})
        end
    after
      30_000 ->
        # Send a ping every 30 seconds to keep connection alive
        try do
          {:ok, conn} = chunk(conn, ": ping\n\n")
          receive_sse_messages(conn, transport, connection_id)
        catch
          :error, :closed ->
            Logger.debug("SSE connection closed: #{connection_id}")
            GenServer.cast(transport, {:remove_connection, connection_id})

          kind, reason ->
            Logger.error("SSE connection error: #{inspect(kind)}, #{inspect(reason)}")
            GenServer.cast(transport, {:remove_connection, connection_id})
        end
    end
  end
end
