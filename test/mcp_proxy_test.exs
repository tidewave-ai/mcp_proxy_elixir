defmodule McpProxyTest do
  use ExUnit.Case
  doctest McpProxy

  alias McpProxy.SSEServer

  test "connects to SSE server running 2024-11-05 protocol" do
    {:ok, port} = SSEServer.start_link()

    parent = self()

    pid =
      spawn_link(fn ->
        Process.group_leader(self(), parent)
        McpProxy.main(["http://localhost:#{port}/sse"])
      end)

    assert_receive {:io_request, ^pid, reply_as, {:get_line, :unicode, []}}

    init = %{
      jsonrpc: "2.0",
      id: "init-1",
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{}
      }
    }

    send(pid, {:io_reply, reply_as, Jason.encode_to_iodata!(init)})

    assert_receive {:io_request, ^pid, reply_as, {:get_line, :unicode, []}}
    assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}
    send(put_pid, {:io_reply, put_reply_as, :ok})

    assert %{"id" => "init-1", "result" => init_response} = Jason.decode!(json)
    assert %{"serverInfo" => %{"name" => "Echo MCP Server"}, "tools" => [tool]} = init_response
    assert tool["name"] == "echo"

    send(
      pid,
      {:io_reply, reply_as,
       Jason.encode_to_iodata!(%{
         jsonrpc: "2.0",
         id: "call-1",
         method: "tools/call",
         params: %{"name" => "echo", "arguments" => %{"what" => "Hey!"}}
       })}
    )

    assert_receive {:io_request, ^pid, _reply_as, {:get_line, :unicode, []}}
    assert_receive {:io_request, put_pid, put_reply_as, {:put_chars, :unicode, json}}
    send(put_pid, {:io_reply, put_reply_as, :ok})

    assert %{"id" => "call-1", "result" => call_response} = Jason.decode!(json)
    assert %{"content" => [%{"text" => "Hey!"}]} = call_response

    # send(pid, {:io_reply, reply_as, :eof})
  end
end
