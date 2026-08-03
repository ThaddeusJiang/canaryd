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

  test "publishes the matching Hex package with a step-scoped secret" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "name: Publish Hex package for ${{ inputs.tag }}"
    assert workflow =~ "HEX_API_KEY: ${{ secrets.HEX_API_KEY }}"
    assert workflow =~ "MIX_ENV: dev"
    assert workflow =~ "mix hex.publish --yes"
  end
end
