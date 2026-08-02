defmodule Canaryd.ReleaseConfigTest do
  use ExUnit.Case, async: true

  test "builds one executable for each macOS architecture" do
    release = Mix.Project.config()[:releases][:canaryd]

    assert [:assemble, wrap] = release[:steps]
    assert is_function(wrap, 1)

    assert release[:burrito][:targets] == [
             macos_arm64: [os: :darwin, cpu: :aarch64],
             macos_x86_64: [os: :darwin, cpu: :x86_64]
           ]
  end
end
