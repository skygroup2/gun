defmodule GunTest do
  use ExUnit.Case
  doctest Gun

  test "greets the world" do
    assert Gun.hello() == :world
  end
end
