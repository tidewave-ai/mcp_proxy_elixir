defmodule McpProxy do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  require Logger

  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          url: :string,
          debug: :boolean
        ]
      )

    base_url =
      Keyword.get_lazy(opts, :url, fn -> System.get_env("SSE_URL") end) ||
        raise "either --url or SSE_URL environment variable must be set"

    debug = Keyword.get(opts, :debug, false)

    if debug do
      Logger.configure(level: :debug)
      Logger.debug("Starting MCP wrapper script with base URL: #{base_url}")
    end

    Application.ensure_all_started(:req)

    # Connect to SSE endpoint and get the message endpoint, then loop and process stdin
    case connect_to_sse(base_url, debug) do
      {:ok, endpoint, sse_pid} ->
        if debug, do: Logger.debug("Received endpoint: #{endpoint}")
        # Monitor the SSE process to detect when it dies
        sse_ref = Process.monitor(sse_pid)
        # Start the stdio loop with the received endpoint
        process_stdio(endpoint, debug, sse_ref)

      {:error, reason} ->
        Logger.error("Failed to connect to SSE endpoint: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp connect_to_sse(sse_url, debug) do
    if debug, do: Logger.debug("Connecting to SSE endpoint: #{sse_url}")

    parent = self()

    # Spawn a process to handle the SSE connection
    pid =
      spawn_link(fn ->
        try do
          # Use Req.get! with into function to process the streaming response
          Req.get!(
            sse_url,
            headers: [{"accept", "text/event-stream"}],
            into: fn {:data, chunk}, {req, resp} ->
              # Process each chunk of data
              process_sse_chunk(chunk, parent, debug)
              # Return {:cont, {req, resp}} to continue streaming
              {:cont, {req, resp}}
            end,
            receive_timeout: :infinity,
            retry: false
          )
        rescue
          e ->
            if debug, do: Logger.debug("Error in SSE connection: #{inspect(e)}")
            send(parent, {:sse_error, e})
        end

        # When SSE connection ends, notify the parent process
        if debug, do: Logger.debug("SSE connection closed")
        send(parent, {:sse_closed})
      end)

    # Wait for the endpoint URL
    receive do
      {:endpoint, endpoint} ->
        {:ok, endpoint, pid}

      {:sse_error, error} ->
        {:error, "SSE connection error: #{inspect(error)}"}

      {:sse_closed} ->
        {:error, "SSE connection closed before receiving endpoint"}
    after
      10_000 ->
        {:error, "Timeout waiting for endpoint URL"}
    end
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
          send(parent, {:endpoint, endpoint})

        {:ok, event_type, data} ->
          if debug, do: Logger.debug("Received SSE event: #{event_type}, data: #{data}")
          # Forward other events to stdout
          case Jason.decode(data) do
            {:ok, parsed_data} ->
              response_json = Jason.encode!(parsed_data)
              IO.write(:stdio, "#{response_json}\n")

            _ ->
              if debug, do: Logger.debug("Failed to parse SSE event data as JSON: #{data}")
          end

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
        line -> String.trim(String.replace(line, "event:", ""))
      end

    data_line =
      lines
      |> Enum.find(fn line -> String.starts_with?(line, "data:") end)
      |> case do
        nil -> nil
        line -> String.trim(String.replace(line, "data:", ""))
      end

    case data_line do
      nil -> {:error, "No data found in SSE event"}
      data -> {:ok, event_type, data}
    end
  end

  defp process_stdio(endpoint, debug, sse_ref) do
    receive do
      {:DOWN, ^sse_ref, :process, _pid, reason} ->
        if debug, do: Logger.debug("SSE connection process terminated: #{inspect(reason)}")
        Logger.info("SSE connection closed, exiting")
        System.halt(0)
    after
      0 -> :ok
    end

    case IO.read(:stdio, :line) do
      :eof ->
        # End of input, exit
        if debug, do: Logger.debug("Stdin closed (EOF), exiting")
        System.halt(0)

      {:error, reason} ->
        Logger.error("Error reading from stdin: #{inspect(reason)}")
        System.halt(1)

      line ->
        if debug, do: Logger.debug("Received input: #{inspect(line)}")

        case Jason.decode(line) do
          {:ok, request} ->
            if debug, do: Logger.debug("Parsed request: #{inspect(request)}")
            # forward a POST to the message endpoint
            forward_request(endpoint, request, debug)

          {:error, error} ->
            if debug,
              do: Logger.debug("JSON parse error: #{inspect(error)}, input was: #{inspect(line)}")

            error = %{
              jsonrpc: "2.0",
              error: %{
                code: -32700,
                message: "Parse error: #{inspect(error)}"
              }
            }

            IO.write(:stdio, "#{Jason.encode!(error)}\n")
        end

        process_stdio(endpoint, debug, sse_ref)
    end
  end

  defp forward_request(endpoint, request, debug) do
    if debug, do: Logger.debug("Sending request to: #{endpoint}")

    req =
      Req.new(
        url: endpoint,
        method: :post,
        json: request,
        headers: [
          {"accept", "application/json"},
          {"content-type", "application/json"}
        ],
        receive_timeout: :infinity,
        retry: false
      )

    result = Req.request(req)
    if debug, do: Logger.debug("Response: #{inspect(result)}")

    case result do
      {:ok, %{status: 200, body: body}} ->
        body

      {:ok, %{status: _status, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status, body: body}} ->
        if debug, do: Logger.debug("Unexpected response body: #{inspect(body)}")

        # Try to parse the body if it's a string
        case is_binary(body) && Jason.decode(body) do
          {:ok, parsed_body} ->
            parsed_body

          _ ->
            %{
              jsonrpc: "2.0",
              error: %{
                code: -32603,
                message: "Internal error",
                data: %{
                  details: "Server responded with status #{status}",
                  body: body
                }
              }
            }
        end

      {:error, exception} ->
        # Handle all error cases
        %{
          jsonrpc: "2.0",
          error: %{
            code: -32603,
            message: "Internal error",
            data: %{
              details: "Error connecting to server: #{inspect(exception)}"
            }
          }
        }
    end
  end
end
