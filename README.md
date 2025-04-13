# McpProxy

<!-- MDOC !-->

An escript for connecting STDIO based MCP clients to HTTP (SSE) based MCP servers.

## Installation

```bash
$ mix escript.install hex mcp_proxy
```

The escript is installed into your HOME's `.mix` directory: `/path/to/home/.mix/escripts/mcp_proxy`.

If you have an SSE MCP server available at `http://localhost:4000/mcp`, a client like Claude Desktop would then be configured like this:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/home/.mix/escripts/mcp_proxy",
      "env": {
        "SSE_URL": "http://localhost:4000/mcp"
      }
    }
  }
}
```

## Configuration

`mcp_proxy` either accepts the SSE URL as parameter `--url` or using the environment variable `SSE_URL`. For debugging purposes, you can also pass `--debug`, which will log debug messages on stderr.
