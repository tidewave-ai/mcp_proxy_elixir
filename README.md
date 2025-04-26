# mcp-proxy

An Elixir escript for connecting STDIO based MCP clients to HTTP (SSE) based MCP servers.

Note: At the moment this only works with MCP servers that use the `2024-11-05` specification.

## Installation

```bash
$ mix escript.install hex mcp_proxy
```

The escript is installed into your HOME's `.mix` directory: `/path/to/home/.mix/escripts/mcp-proxy`.

## Usage

If you have an SSE MCP server available at `http://localhost:4000/tidewave/mcp`, a client like Claude Desktop would then be configured as follows.

### On macos/Linux

You will also need to know the location of the `escript` executable, so run `which escript` before to get the value of "path/to/escript":

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/escript",
      "args": ["/$HOME/.mix/escripts/mcp-proxy", "http://localhost:4000/tidewave/mcp"]
    }
  }
}
```

Remember to replace `$HOME` by your home directory, such as "/Users/johndoe".

### On Windows

```json
{
  "mcpServers": {
    "my-server": {
      "command": "escript.exe",
      "args": ["c:\$HOME\.mix\escripts\mcp-proxy", "http://localhost:4000/tidewave/mcp"]
    }
  }
}
```

Remember to replace `$HOME` by your home directory, such as "c:\Users\johndoe".

## Configuration

`mcp-proxy` either accepts the SSE URL as argument or using the environment variable `SSE_URL`. For debugging purposes, you can also pass `--debug`, which will log debug messages on stderr.

Other supported flags:

* `--max-disconnected-time` the maximum amount of time for trying to reconnect while disconnected. When not set, defaults to infinity.
* `--receive-timeout` the maximum amount of time to wait for an individual reply from the MCP server in milliseconds. Defaults to 60000 (60 seconds).
