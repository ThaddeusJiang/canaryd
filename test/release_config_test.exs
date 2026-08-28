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

  test "installs the pinned Zig release without a Node 20 action" do
    workflow = File.read!(".github/workflows/release.yml")

    refute workflow =~ "mlugg/setup-zig"
    assert workflow =~ "https://ziglang.org/download/0.16.0/"
    assert workflow =~ "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
    assert workflow =~ "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"
    assert workflow =~ "shasum -a 256 -c -"
  end

  test "requires Node.js 24 for the HyperFrames source project" do
    package_json = File.read!("hyperframes-src/canaryd-core-stories/package.json")
    package_lock = File.read!("hyperframes-src/canaryd-core-stories/package-lock.json")

    assert package_json =~ ~s("node": ">=24.0.0")
    assert package_lock =~ ~s("node": ">=24.0.0")
  end

  test "publishes the matching Hex package with a step-scoped secret" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "name: Publish Hex package for ${{ inputs.tag }}"
    assert workflow =~ "HEX_API_KEY: ${{ secrets.HEX_API_KEY }}"
    assert workflow =~ "MIX_ENV: dev"
    assert workflow =~ "mix hex.publish --yes"
  end
end
