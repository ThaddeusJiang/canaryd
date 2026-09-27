defmodule Canaryd.RuntimeDependenciesTest do
  use ExUnit.Case, async: true

  test "release includes crypto for cleanup hashing and clipboard signatures" do
    assert :crypto in Application.spec(:canaryd, :applications)
    assert byte_size(:crypto.hash(:md5, "workspace")) == 16
  end
end
