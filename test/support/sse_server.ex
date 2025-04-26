defmodule McpProxy.SSEServer do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(opts) do
    children = [
      {Registry, keys: :unique, name: __MODULE__.Registry},
      {Bandit,
       plug: __MODULE__.Router,
       port: opts[:port] || 0,
       thousand_island_options: [
         shutdown_timeout: 10,
         supervisor_options: [name: {:via, Registry, {__MODULE__.Registry, Bandit}}]
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def port do
    [{pid, _}] = Registry.lookup(__MODULE__.Registry, Bandit)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defmodule Router do
    use Plug.Router

    plug(:match)

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:dispatch)

    get "/sse" do
      session_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64()
      {:ok, _} = Registry.register(McpProxy.SSEServer.Registry, session_id, nil)

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
            try do
              :gen_server.enter_loop(McpProxy.SSEServer.Echo, [], %{
                session_id: session_id,
                conn: conn
              })
            catch
              :exit, :normal -> conn
              :exit, :shutdown -> conn
            after
              send(self(), {:plug_conn, :sent})
            end

          {:error, :closed} ->
            conn
        end
      end)
    end

    post "/message" do
      with %{query_params: %{"session_id" => session_id}} <- conn,
           [{pid, _}] <- Registry.lookup(McpProxy.SSEServer.Registry, session_id) do
        GenServer.call(pid, {:request, conn.body_params})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{status: "ok"}))
      end
    end
  end

  defmodule Echo do
    use GenServer

    @impl GenServer
    def init(_) do
      {:ok, nil}
    end

    @impl GenServer
    def handle_call({:request, message}, _from, state) do
      result = handle_message(message)

      if result do
        case Plug.Conn.chunk(state.conn, ["event: message\ndata: ", result]) do
          {:ok, conn} -> {:reply, :ok, %{state | conn: conn}}
          {:error, :closed} -> {:stop, :shutdown, state}
        end
      else
        {:reply, :ok, state}
      end
    end

    @impl GenServer
    def handle_info(_other, state) do
      {:noreply, state}
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

    defp handle_message(%{"method" => "notifications/initialized"}), do: nil

    defp handle_message(%{"id" => request_id, "method" => "ping"}) do
      Jason.encode_to_iodata!(%{jsonrpc: 2.0, id: request_id, result: %{}})
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

    defp handle_message(%{
           "id" => request_id,
           "method" => "tools/call",
           "params" => %{"name" => "sleep", "arguments" => %{"time" => time}}
         }) do
      Process.sleep(time)

      Jason.encode_to_iodata!(%{
        jsonrpc: "2.0",
        id: request_id,
        result: %{content: [%{text: "Ok"}]}
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
