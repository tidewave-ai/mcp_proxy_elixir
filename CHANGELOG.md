# Changelog

## 0.3.1 (2025-04-26)

* Enhancements
  * add configurable `--receive-timeout` for POST requests (defaults to 60 seconds).
    Note: the proxy will reply to the MCP request with an error response and discard
    the real response if it arrives after the timeout. Previously, POST requests timed
    out after 15 seconds.

## 0.3.0 (2025-04-23)

* Enhancements
  * Automatically try to reconnect when the SSE connection closes.
    This can be adjusted by setting the `--max-disconnected-time` parameter,
    which defines the number of seconds the proxy tries to reconnect. By default, it retries
    indefinitely. To close the proxy on disconnect, this value can be set to `0`.
  * Notice: in order to support reconnects, the proxy transparently rewrites the IDs of
    received and sent JSON ID messages.

## 0.2.0 (2025-04-22)

* API adjustments
  * the escript is called `mcp-proxy` instead of `mcp_proxy` now
  * remove `--url` flag and use first argument instead: `mcp-proxy http://localhost:4000/tidewave/mcp`
* Bug fixes:
  * ensure script terminates early when SSE connection closes

## 0.1.0 (2025-04-14)

Initial release.
