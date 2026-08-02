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

  test "publishes rc tags as GitHub prereleases" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "(-rc\\.[1-9][0-9]*)?"
    assert workflow =~ "release_flags+=(--prerelease)"
    assert workflow =~ ~S("${release_flags[@]}")
  end
end
