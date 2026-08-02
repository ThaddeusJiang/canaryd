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

  test "delegates release logic to the release script" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "scripts/release.sh validate"
    assert workflow =~ "scripts/release.sh build"
    assert workflow =~ "scripts/release.sh publish"
    refute workflow =~ "codesign --force"
    refute workflow =~ "gh release create"
  end
end
