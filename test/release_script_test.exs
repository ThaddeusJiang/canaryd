defmodule Canaryd.ReleaseScriptTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../scripts/release.sh", __DIR__)

  test "rejects an invalid release tag" do
    {output, status} = run_script("validate", [{"TAG", "v0.3.0-beta.1"}])

    assert status != 0
    assert output =~ "Invalid release tag: v0.3.0-beta.1"
  end

  test "requires confirmation for release configuration changes" do
    fixture = release_fixture()

    {output, status} =
      run_script(
        "validate",
        [{"TAG", "v0.3.0-rc.1"}],
        fixture.root
      )

    assert status != 0
    assert output =~ "- Base: v0.2.0"
    assert output =~ "- Config files: mix.exs"
    assert output =~ "Release configuration changes need explicit confirmation."
  end

  test "accepts confirmed release configuration changes" do
    fixture = release_fixture()

    assert {output, 0} =
             run_script(
               "validate",
               [
                 {"CONFIG_CHANGES_CONFIRMED", "true"},
                 {"TAG", "v0.3.0-rc.1"}
               ],
               fixture.root
             )

    assert output =~ "- Target: v0.3.0-rc.1"
  end

  test "publishes an rc tag as a GitHub prerelease" do
    fixture = gh_fixture()

    assert {_, 0} =
             run_script("publish", [
               {"GH_ARGS_FILE", fixture.args_file},
               {"PATH", fixture.path},
               {"TAG", "v0.3.0-rc.1"}
             ])

    arguments = File.read!(fixture.args_file)
    assert arguments =~ "create\n"
    assert arguments =~ "v0.3.0-rc.1\n"
    assert arguments =~ "--prerelease\n"
  end

  test "publishes a stable tag without the prerelease flag" do
    fixture = gh_fixture()

    assert {_, 0} =
             run_script("publish", [
               {"GH_ARGS_FILE", fixture.args_file},
               {"PATH", fixture.path},
               {"TAG", "v0.3.0"}
             ])

    refute File.read!(fixture.args_file) =~ "--prerelease\n"
  end

  defp gh_fixture do
    root =
      Path.join(System.tmp_dir!(), "canaryd-release-test-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(root, "bin")
    args_file = Path.join(root, "gh-args")
    File.mkdir_p!(bin_dir)

    gh_path = Path.join(bin_dir, "gh")

    File.write!(gh_path, """
    #!/usr/bin/env bash
    if [ "$1" = "release" ] && [ "$2" = "view" ]; then
      exit 1
    fi
    printf '%s\n' "$@" > "$GH_ARGS_FILE"
    """)

    File.chmod!(gh_path, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    %{args_file: args_file, path: "#{bin_dir}:#{System.get_env("PATH")}"}
  end

  defp release_fixture do
    root =
      Path.join(System.tmp_dir!(), "canaryd-release-git-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "release-test@example.com"])
    git!(root, ["config", "user.name", "Release Test"])

    write_mix_version(root, "0.2.0")
    git!(root, ["add", "mix.exs"])
    git!(root, ["commit", "--quiet", "-m", "chore: add release base"])
    git!(root, ["tag", "v0.2.0"])

    write_mix_version(root, "0.3.0-rc.1")
    git!(root, ["add", "mix.exs"])
    git!(root, ["commit", "--quiet", "-m", "chore: add release candidate"])
    git!(root, ["tag", "v0.3.0-rc.1"])

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write_mix_version(root, version) do
    File.write!(Path.join(root, "mix.exs"), """
    defmodule ReleaseFixture.MixProject do
      def project do
        [
          version: "#{version}",
        ]
      end
    end
    """)
  end

  defp git!(root, arguments) do
    assert {_, 0} = System.cmd("git", arguments, cd: root, stderr_to_stdout: true)
  end

  defp run_script(command, environment, working_directory \\ File.cwd!()) do
    System.cmd("bash", [@script_path, command],
      cd: working_directory,
      env: environment,
      stderr_to_stdout: true
    )
  end
end
