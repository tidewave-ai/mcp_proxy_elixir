defmodule McpProxy do
  @moduledoc false
  require Logger

  alias McpProxy.SSE

  @doc false
  def main(args) do
    {opts, args} =
      OptionParser.parse!(args,
        strict: [
          debug: :boolean,
          max_disconnected_time: :integer,
          receive_timeout: :integer
        ]
      )

    base_url =
      case args do
        [arg_url] ->
          arg_url

        [] ->
          System.get_env("SSE_URL") ||
            raise "either the URL is passed as first argument or the SSE_URL environment variable must be set"

        many ->
          raise "expected one or zero arguments, got: #{inspect(many)}"
      end

    Application.ensure_all_started(:req)
    Application.put_all_env(mcp_proxy: opts)

    {:ok, handler} = SSE.start_link(base_url)
    ref = Process.monitor(handler)

    receive do
      {:DOWN, ^ref, _, _, reason} ->
        System.stop((reason == :normal && 0) || 1)
    end
  end
end
