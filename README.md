# mcp-proxy

An Elixir escript for connecting STDIO based MCP clients to HTTP (SSE) based MCP servers.

Note: At the moment this only works with MCP servers that use the `2024-11-05` specification.

## Installation

```bash
$ mix escript.install hex mcp_proxy
```

The escript is installed into your HOME's `.mix` directory: `/path/to/home/.mix/escripts/mcp-proxy`. It is advised to add the escripts directory to your `$PATH` but you can use the full path if preferred.

If you have an SSE MCP server available at `http://localhost:4000/tidewave/mcp`, a client like Claude Desktop would then be configured like this:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/home/.mix/escripts/mcp-proxy",
      "args": ["http://localhost:4000/tidewave/mcp"]
    }
  }
}
```

## Configuration

`mcp-proxy` either accepts the SSE URL as argument or using the environment variable `SSE_URL`. For debugging purposes, you can also pass `--debug`, which will log debug messages on stderr.
