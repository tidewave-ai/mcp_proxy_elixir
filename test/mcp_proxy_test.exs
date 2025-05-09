defmodule McpProxyTest do
  use ExUnit.Case, async: false
  doctest McpProxy

  import ExUnit.CaptureIO

  alias McpProxy.SSEServer

  setup context do
    {result, output} =
      with_io(:stderr, fn ->
        _server_pid = start_supervised!(SSEServer, restart: :temporary)
        port = SSEServer.port()

        parent = self()

        _main_pid =
          spawn_link(fn ->
            Process.group_leader(self(), parent)

            McpProxy.main(
              ["http://localhost:#{port}/sse", "--debug"] ++ (context[:extra_args] || [])
            )
          end)

        assert_receive {:io_request, io_pid, reply_as, {:get_line, :unicode, []}}

        send_message(io_pid, reply_as, %{
          jsonrpc: "2.0",
          id: "init-1",
          method: "initialize",
          params: %{
            protocolVersion: "2024-11-05",
            capabilities: %{}
          }
        })

        assert_receive {:io_request, ^io_pid, reply_as, {:get_line, :unicode, []}}
        assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 1000
        send(put_pid, {:io_reply, put_reply_as, :ok})

        assert %{"id" => "init-1", "result" => init_response} = Jason.decode!(json)

        assert %{"serverInfo" => %{"name" => "Echo MCP Server"}, "tools" => [tool]} =
                 init_response

        assert tool["name"] == "echo"

        send_message(io_pid, reply_as, %{
          jsonrpc: "2.0",
          method: "notifications/initialized"
        })

        assert_receive {:io_request, ^io_pid, reply_as, {:get_line, :unicode, []}}

        %{port: port, io_pid: io_pid, reply_as: reply_as}
      end)

    ["Found endpoint: " <> endpoint_url] = Regex.run(~r/Found endpoint: .*/, output)
    %{"session_id" => session_id} = URI.new!(endpoint_url).query |> URI.decode_query()
    [{sse_pid, _}] = Registry.lookup(McpProxy.SSEServer.Registry, session_id)

    Map.merge(result, %{session_id: session_id, sse_pid: sse_pid})
  end

  test "connects to SSE server running 2024-11-05 protocol", %{io_pid: io_pid, reply_as: reply_as} do
    capture_io(:stderr, fn ->
      send_message(
        io_pid,
        reply_as,
        %{
          jsonrpc: "2.0",
          id: "call-1",
          method: "tools/call",
          params: %{"name" => "echo", "arguments" => %{"what" => "Hey!"}}
        }
      )

      assert_receive {:io_request, ^io_pid, _reply_as, {:get_line, :unicode, []}}
      assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 5000
      send(put_pid, {:io_reply, put_reply_as, :ok})

      assert %{"id" => "call-1", "result" => call_response} = Jason.decode!(json)
      assert %{"content" => [%{"text" => "Hey!"}]} = call_response
    end)
  end

  test "handles server reconnects gracefully", %{
    io_pid: io_pid,
    reply_as: reply_as,
    port: port
  } do
    io =
      capture_io(:stderr, fn ->
        # bye bye, server!
        stop_supervised!(SSEServer)

        # now send a client request
        send_message(
          io_pid,
          reply_as,
          %{
            jsonrpc: "2.0",
            id: "call-1",
            method: "tools/call",
            params: %{"name" => "echo", "arguments" => %{"what" => "Hey!"}}
          }
        )

        # now start the server again
        start_supervised!({SSEServer, [port: port]})

        assert_receive {:io_request, _io_pid, _reply_as, {:get_line, :unicode, []}}

        assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 5000
        send(put_pid, {:io_reply, put_reply_as, :ok})

        assert %{"id" => "call-1", "result" => call_response} = Jason.decode!(json)
        assert %{"content" => [%{"text" => "Hey!"}]} = call_response
      end)

    assert io =~ "SSE connection closed. Trying to reconnect"
    assert io =~ "Flushing buffer"
  end

  @tag extra_args: ["--receive-timeout", "50"]
  test "handles receive timeout", %{io_pid: io_pid, reply_as: reply_as} do
    capture_io(:stderr, fn ->
      send_message(
        io_pid,
        reply_as,
        %{
          jsonrpc: "2.0",
          id: "call-1",
          method: "tools/call",
          params: %{"name" => "sleep", "arguments" => %{"time" => 100}}
        }
      )

      assert_receive {:io_request, _io_pid, _reply_as, {:get_line, :unicode, []}}
      assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 100
      send(put_pid, {:io_reply, put_reply_as, :ok})

      assert %{"id" => "call-1", "error" => %{"message" => message}} = Jason.decode!(json)
      assert message =~ "Failed to forward request"

      # wait an extra 100 milliseconds for the log about discarding a duplicate response
      Process.sleep(100)
    end) =~ "Discarding!"
  end

  test "ignores notifications while disconnected", %{
    io_pid: io_pid,
    reply_as: reply_as,
    port: port
  } do
    io =
      capture_io(:stderr, fn ->
        # bye bye, server!
        stop_supervised!(SSEServer)

        # now send a client request
        send_message(
          io_pid,
          reply_as,
          %{
            jsonrpc: "2.0",
            method: "notifications/cancelled",
            params: %{"reason" => "Error: MCP error -32001: Request timed out", "requestId" => 6}
          }
        )

        # now start the server again
        start_supervised!({SSEServer, [port: port]})

        assert_receive {:io_request, io_pid, reply_as, {:get_line, :unicode, []}}

        send_message(
          io_pid,
          reply_as,
          %{
            jsonrpc: "2.0",
            id: "call-1",
            method: "tools/call",
            params: %{"name" => "echo", "arguments" => %{"what" => "Hey!"}}
          }
        )

        assert_receive {:io_request, _io_pid, _reply_as, {:get_line, :unicode, []}}

        assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 5000
        send(put_pid, {:io_reply, put_reply_as, :ok})

        assert %{"id" => "call-1", "result" => call_response} = Jason.decode!(json)
        assert %{"content" => [%{"text" => "Hey!"}]} = call_response
      end)

    assert io =~ "Ignoring notification while disconnected"
  end

  test "ignores comments", %{
    io_pid: io_pid,
    reply_as: reply_as,
    sse_pid: sse_pid
  } do
    io =
      capture_io(:stderr, fn ->
        # send a comment
        GenServer.cast(sse_pid, {:send_sse, ": hello world"})

        send_message(
          io_pid,
          reply_as,
          %{
            jsonrpc: "2.0",
            id: "call-1",
            method: "tools/call",
            params: %{"name" => "echo", "arguments" => %{"what" => "Hey!"}}
          }
        )

        assert_receive {:io_request, _io_pid, _reply_as, {:get_line, :unicode, []}}

        assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}, 5000
        send(put_pid, {:io_reply, put_reply_as, :ok})

        assert %{"id" => "call-1", "result" => call_response} = Jason.decode!(json)
        assert %{"content" => [%{"text" => "Hey!"}]} = call_response
      end)

    assert io =~ "Ignoring SSE line"
  end

  defp send_message(io_pid, reply_as, json) do
    send(io_pid, {:io_reply, reply_as, Jason.encode_to_iodata!(json)})
  end
end
