defmodule McpProxy.SSE do
  @moduledoc false

  use GenServer

  require Logger

  # unused, just for documentation purposes
  @type state :: %{
          url: binary(),
          endpoint: binary() | nil,
          debug: boolean(),
          max_disconnected_time: integer() | nil,
          disconnected_since: DateTime.t() | nil,
          state:
            :connecting
            | :connected
            | :waiting_for_endpoint
            | :waiting_for_client_init
            | {:waiting_for_server_init, binary() | integer()}
            | {:waiting_for_server_init_hidden, binary() | integer()}
            | :waiting_for_client_initialized,
          connect_tries: non_neg_integer(),
          init_message: nil | map(),
          id_map: map(),
          io_pid: pid() | nil,
          http_pid: pid() | nil,
          in_buf: list(),
          buf_mode: :store | :fail
        }

  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg)
  end

  @impl true
  def init({sse_url, opts}) do
    {:ok,
     %{
       url: sse_url,
       endpoint: nil,
       debug: Keyword.get(opts, :debug, false),
       max_disconnected_time: Keyword.get(opts, :max_disconnected_time),
       disconnected_since: nil,
       state: :connecting,
       connect_tries: 0,
       # the init message is replayed when reconnecting
       init_message: nil,
       id_map: %{},
       io_pid: nil,
       http_pid: nil,
       in_buf: [],
       buf_mode: :store
     }, {:continue, :connect_to_sse}}
  end

  defguardp is_request(map) when is_map_key(map, "id") and is_map_key(map, "method")

  defguardp is_response(map)
            when is_map_key(map, "id") and (is_map_key(map, "result") or is_map_key(map, "error"))

  @impl true
  def handle_continue(:connect_to_sse, %{http_pid: nil} = state) do
    if state.debug, do: Logger.debug("Connecting to SSE: #{state.url}")

    {:noreply, spawn_http_process(state)}
  end

  def handle_continue(:flush_in_buf, %{in_buf: in_buf} = state) do
    if state.debug, do: Logger.debug("Flushing buffer: #{length(in_buf)} messages")

    for event <- Enum.reverse(in_buf) do
      send(self(), {:io_event, event})
    end

    {:noreply, %{state | in_buf: []}}
  end

  defp spawn_http_process(state) do
    if state.debug, do: Logger.debug("Starting HTTP process")

    parent = self()

    pid =
      spawn(fn ->
        Req.new()
        |> Req.get!(
          url: state.url,
          headers: [{"accept", "text/event-stream"}],
          into: fn {:data, chunk}, {req, resp} ->
            process_sse_chunk(chunk, parent, state.debug)
            # Return {:cont, {req, resp}} to continue streaming
            {:cont, {req, resp}}
          end,
          receive_timeout: :infinity,
          retry: false
        )
      end)

    Process.monitor(pid)

    %{state | http_pid: pid, state: :waiting_for_endpoint}
  end

  defp process_sse_chunk(chunk, parent, debug) do
    if debug, do: Logger.debug("Received SSE chunk: #{inspect(chunk)}")

    # Split the chunk into lines and process each event
    chunk
    |> String.split("\n\n", trim: true)
    |> Enum.each(fn event_data ->
      case parse_sse_event(event_data) do
        {:ok, "endpoint", endpoint} ->
          if debug, do: Logger.debug("Found endpoint: #{endpoint}")
          send(parent, {:sse_event, {:endpoint, endpoint}})

        {:ok, "message", data} ->
          decoded = Jason.decode!(data)
          send(parent, {:sse_event, {:message, decoded}})

        {:ok, event_type, data} ->
          if debug, do: Logger.debug("Received SSE event: #{event_type}, data: #{data}")
          send(parent, {:sse_event, {event_type, data}})

        {:error, error} ->
          if debug, do: Logger.debug("Error parsing SSE event: #{inspect(error)}")
      end
    end)
  end

  defp parse_sse_event(data) do
    lines = String.split(data, "\n", trim: true)

    event_type =
      lines
      |> Enum.find(fn line -> String.starts_with?(line, "event:") end)
      |> case do
        nil -> "message"
        line -> String.trim(String.replace_prefix(line, "event:", ""))
      end

    data_line =
      lines
      |> Enum.find(fn line -> String.starts_with?(line, "data:") end)
      |> case do
        nil -> nil
        line -> String.trim(String.replace_prefix(line, "data:", ""))
      end

    case data_line do
      nil -> {:error, "No data found in SSE event"}
      data -> {:ok, event_type, data}
    end
  end

  defp spawn_io_process(state) do
    if state.debug, do: Logger.debug("Starting IO process")

    parent = self()
    pid = spawn_link(fn -> io_loop(parent) end)

    %{state | io_pid: pid}
  end

  defp io_loop(parent) do
    case IO.read(:stdio, :line) do
      :eof ->
        :eof

      {:error, reason} ->
        send(parent, {:io_error, reason})

      line ->
        send(parent, {:io_event, Jason.decode!(line)})
        io_loop(parent)
    end
  end

  @impl true
  def handle_info(
        {:sse_event, {:endpoint, endpoint}},
        %{state: :waiting_for_endpoint} = state
      ) do
    if init_message = state.init_message do
      # this is a reconnect, as we already have an init message stored
      # therefore we forward the existing message to the server and wait in
      # the special :waiting_for_server_init_hidden state, that discards the response
      forward_message(init_message, endpoint, state.debug)

      {:noreply,
       %{state | state: {:waiting_for_server_init_hidden, init_message["id"]}, endpoint: endpoint}}
    else
      Logger.debug("waiting for client init")
      {:noreply, %{spawn_io_process(state) | endpoint: endpoint, state: :waiting_for_client_init}}
    end
  end

  def handle_info(
        {:io_event, %{"method" => "initialize", "id" => client_id} = init_message},
        %{state: :waiting_for_client_init} = state
      ) do
    if state.debug,
      do: Logger.debug("Got client init: #{inspect(init_message)}")

    forward_message(init_message, state.endpoint, state.debug)

    {:noreply,
     %{state | state: {:waiting_for_server_init, client_id}, init_message: init_message}}
  end

  # initialization reply
  def handle_info(
        {:sse_event, {:message, %{"id" => init_id} = message}},
        %{state: {:waiting_for_server_init, init_id}} = state
      ) do
    IO.puts(Jason.encode!(message))

    {:noreply, %{state | state: :waiting_for_client_initialized}}
  end

  # this is the init reply, but we are reconnecting (waiting_for_server_init_hidden),
  # so we don't actually forward it to the client
  def handle_info(
        {:sse_event, {:message, %{"id" => init_id}}},
        %{state: {:waiting_for_server_init_hidden, init_id}} = state
      ) do
    # for protocol compliance, we need to also send the initialized notification
    forward_message(
      %{"method" => "notifications/initialized", "jsonrpc" => "2.0"},
      state.endpoint,
      state.debug
    )

    {:noreply, connected_state(state), {:continue, :flush_in_buf}}
  end

  def handle_info({:io_event, %{"method" => "notifications/initialized"} = event}, state) do
    forward_message(event, state.endpoint, state.debug)

    {:noreply, connected_state(state), {:continue, :flush_in_buf}}
  end

  # store or reply with an error for events coming from the client
  # while we are not connected
  def handle_info({:io_event, event}, state)
      when state.state not in [:connected, :waiting_for_client_init] do
    case event do
      %{"method" => "ping", "id" => request_id} ->
        # we directly answer ping requests
        IO.puts(Jason.encode!(%{jsonrpc: "2.0", id: request_id, result: %{}}))
        {:noreply, state}

      %{"method" => "tools/call"} when state.buf_mode == :store ->
        # we store tool calls for later
        {:noreply, %{state | in_buf: [event | state.in_buf]}}

      %{"method" => _other, "id" => request_id} ->
        # we answer with an error
        reply_disconnected(request_id)

        {:noreply, state}
    end
  end

  # regular events
  def handle_info({:sse_event, {:message, event}}, state),
    do: handle_event(event, state, &IO.puts(Jason.encode!(&1)))

  def handle_info({:io_event, event}, state),
    do: handle_event(event, state, &forward_message(&1, state.endpoint, state.debug))

  # whenever the HTTP process dies, we try to reconnect
  def handle_info({:DOWN, _ref, :process, http_pid, _reason}, %{http_pid: http_pid} = state) do
    backoff = min(2 ** state.connect_tries, 8)

    Logger.info("SSE connection closed. Trying to reconnect in #{backoff}s.")
    Process.send_after(self(), :reconnect, to_timeout(second: backoff))

    if state.connect_tries == 0 do
      # we give the server 20 seconds to reconnect and store incoming
      # tool calls, but after that we reply with an error
      Process.send_after(self(), :fail_flush, to_timeout(second: 20))
    end

    if disconnected_too_long?(state) do
      {:stop, {:shutdown, :reconnect_timeout}, state}
    else
      {:noreply,
       %{
         state
         | state: :disconnected,
           endpoint: nil,
           http_pid: nil,
           disconnected_since: state.disconnected_since || DateTime.utc_now(),
           connect_tries: state.connect_tries + 1
       }}
    end
  end

  # whenever the IO process dies, we can stop, as this means that
  # the client itself disconnected
  def handle_info({:DOWN, _ref, :process, io_pid, _reason}, %{io_pid: io_pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect_to_sse}}
  end

  def handle_info({:io_error, error}, state) do
    Logger.error("Error reading from stdin: #{inspect(error)}")
    {:stop, {:shutdown, :io_error}, state}
  end

  def handle_info(:fail_flush, state) do
    Logger.info("Did not reconnect in time. Flushing buffer, replying with errors!")

    for message <- state.in_buf do
      reply_disconnected(message["id"])
    end

    {:noreply, %{state | in_buf: [], buf_mode: :fail}}
  end

  # json rpc batch (we don't necessarily need to handle this, as we only expect the 2024-11-05 protocol for now)
  defp handle_event(messages, state, handler) when is_list(messages) do
    Enum.reduce(messages, state, fn message, state -> handle_event(message, state, handler) end)
  end

  defp handle_event(%{"jsonrpc" => "2.0", "id" => request_id} = event, state, handler)
       when is_request(event) do
    # whenever we get a request from the client (OR the server!)
    # we generate a random ID to prevent duplicate IDs, for example when
    # a reconnected server decides to send a ping and always starts with ID 0
    new_id = random_id!()
    event = Map.put(event, "id", new_id)

    handler.(event)

    {:noreply, %{state | id_map: Map.put(state.id_map, new_id, request_id)}}
  end

  defp handle_event(%{"jsonrpc" => "2.0", "id" => response_id} = event, state, handler)
       when is_response(event) do
    # whenever we receive a response (from the client or server)
    # we fetch the original ID from the id map to present the expected
    # ID in the reply
    original_id = Map.fetch!(state.id_map, response_id)
    event = Map.put(event, "id", original_id)

    handler.(event)

    {:noreply, %{state | id_map: Map.delete(state.id_map, response_id)}}
  end

  # no id, so must be a notification that we can just forward as is
  defp handle_event(%{"jsonrpc" => "2.0"} = event, state, handler) do
    handler.(event)

    {:noreply, state}
  end

  ## other helpers

  defp forward_message(message, endpoint, debug) do
    try do
      if debug, do: Logger.debug("Forwarding request to server: #{inspect(message)}")
      Req.post!(endpoint, json: message)
    rescue
      error ->
        Logger.error(
          "Failed to forward message: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        # TODO: store message and replay later?
    end
  end

  defp random_id! do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp disconnected_too_long?(%{max_disconnected_time: seconds, disconnected_since: ts})
       when is_integer(seconds) and is_struct(ts, DateTime) do
    DateTime.diff(DateTime.utc_now(), ts, :second) > seconds
  end

  defp disconnected_too_long?(_), do: false

  defp reply_disconnected(id) do
    IO.puts(
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        error: %{
          code: -32010,
          message:
            "Server not connected. The SSE endpoint is currently not available. Please ensure it is running and retry."
        }
      })
    )
  end

  defp connected_state(state) do
    %{state | state: :connected, connect_tries: 0, disconnected_since: nil, buf_mode: :store}
  end
end
