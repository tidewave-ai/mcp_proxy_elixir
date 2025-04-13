defmodule McpProxyTest do
  use ExUnit.Case
  doctest McpProxy

  test "greets the world" do
    assert McpProxy.hello() == :world
  end
end
