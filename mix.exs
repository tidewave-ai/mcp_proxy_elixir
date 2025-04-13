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
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs()
    ]
  end

  defp escript do
    [
      main_module: McpProxy,
      name: "mcp_proxy",
      app: nil,
      path: "mcp_proxy"
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
      main: "McpProxy",
      source_ref: "v#{@version}",
      source_url: "https://github.com/tidewave-ai/mcp_proxy"
    ]
  end
end
