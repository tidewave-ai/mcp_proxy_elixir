defmodule McpProxy.SSEServer do
  use Plug.Router

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  def start_link do
    {:ok, _pid} = Registry.start_link(keys: :unique, name: __MODULE__.Registry)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    {:ok, port}
  end

  get "/sse" do
    session_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64()
    {:ok, _} = Registry.register(__MODULE__.Registry, session_id, nil)

    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
    |> send_chunked(200)
    |> tap(fn conn ->
      # initial endpoint message
      endpoint = "#{conn.scheme}://#{conn.host}:#{conn.port}/message?session_id=#{session_id}"

      case chunk(conn, "event: endpoint\ndata: #{endpoint}\n\n") do
        {:ok, conn} ->
          :gen_server.enter_loop(__MODULE__.Echo, [], %{session_id: session_id, conn: conn})

        {:error, :closed} ->
          conn
      end
    end)
  end

  post "/message" do
    with %{query_params: %{"session_id" => session_id}} <- conn,
         [{pid, _}] <- Registry.lookup(__MODULE__.Registry, session_id) do
      GenServer.cast(pid, {:request, conn.body_params})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{status: "ok"}))
    end
  end

  defmodule Echo do
    use GenServer

    @impl GenServer
    def init(_) do
      {:ok, nil}
    end

    @impl GenServer
    def handle_cast({:request, message}, state) do
      result = handle_message(message)

      case chunk(state.conn, ["event: message\ndata: ", result]) do
        {:ok, conn} -> {:noreply, %{state | conn: conn}}
        {:error, :closed} -> {:stop, :shutdown, state}
      end
    end

    defp handle_message(%{"id" => request_id, "method" => "initialize"}) do
      Jason.encode_to_iodata!(%{
        jsonrpc: "2.0",
        id: request_id,
        result: %{
          protocolVersion: "2024-11-05",
          capabilities: %{
            tools: %{
              listChanged: false
            }
          },
          serverInfo: %{
            name: "Echo MCP Server",
            version: "1.0.0"
          },
          tools: [
            %{
              name: "echo",
              description: "Echo!",
              inputSchema: %{
                type: "object",
                required: ["what"],
                properties: %{
                  what: %{
                    type: "string",
                    description: "The string to echo"
                  }
                }
              }
            }
          ]
        }
      })
    end

    defp handle_message(%{
           "id" => request_id,
           "method" => "tools/call",
           "params" => %{"name" => "echo", "arguments" => %{"what" => what}}
         }) do
      Jason.encode_to_iodata!(%{
        jsonrpc: "2.0",
        id: request_id,
        result: %{content: [%{text: what}]}
      })
    end

    defp handle_message(%{"id" => id, "method" => other} = _message) do
      Jason.encode_to_iodata!(%{
        jsonrpc: "2.0",
        id: id,
        error: %{
          code: -32601,
          message: "Method not found",
          data: %{
            name: other
          }
        }
      })
    end
  end
end
