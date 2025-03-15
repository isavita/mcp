defmodule MCPTest do
  use ExUnit.Case
  doctest MCP

  test "greets the world" do
    assert MCP.hello() == :world
  end
end
