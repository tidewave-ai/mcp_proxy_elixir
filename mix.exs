defmodule McpProxy.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mcp_proxy,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs()
    ]
  end

  defp escript do
    [
      main_module: McpProxy,
      name: "mcp-proxy",
      path: "mcp-proxy"
    ]
  end

  defp description() do
    "An escript for connecting STDIO based MCP clients to HTTP (SSE) based MCP servers."
  end

  defp package do
    [
      maintainers: ["Steffen Deusch", "José Valim"],
      licenses: ["Apache-2.0"],
      links: %{
        GitHub: "https://github.com/tidewave-ai/mcp_proxy_elixir"
      },
      files: [
        "lib",
        "LICENSE",
        "mix.exs",
        "README.md",
        ".formatter.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6", only: :test},
      {:ex_doc, "~> 0.37.3", only: :dev},
      {:makeup_json, "~> 1.0", only: :dev}
    ]
  end

  defp docs do
    [
      api_reference: false,
      main: "readme",
      source_ref: "v#{@version}",
      source_url: "https://github.com/tidewave-ai/mcp_proxy",
      extras: ["README.md"]
    ]
  end
end
