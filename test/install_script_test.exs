defmodule Canaryd.InstallScriptTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../scripts/install.sh", __DIR__)
  @asset "canaryd-aarch64-apple-darwin.tar.gz"

  test "installs a verified executable as canaryd" do
    fixture = release_fixture(valid_checksum?: true)

    {output, status} = run_installer(fixture)

    assert status == 0
    assert output =~ "Installed canaryd 0.2.0"
    assert File.read!(Path.join(fixture.install_dir, "canaryd")) =~ "canaryd 0.2.0"
    assert Bitwise.band(File.stat!(Path.join(fixture.install_dir, "canaryd")).mode, 0o111) != 0
  end

  test "does not install an archive with an invalid checksum" do
    fixture = release_fixture(valid_checksum?: false)

    {_output, status} = run_installer(fixture)

    assert status != 0
    refute File.exists?(Path.join(fixture.install_dir, "canaryd"))
  end

  test "adds the install directory to the current shell profile once" do
    fixture = release_fixture(valid_checksum?: true)
    profile_path = Path.join(Path.dirname(fixture.install_dir), ".zshrc")

    environment = [
      {"CANARYD_PROFILE_PATH", profile_path},
      {"CANARYD_SKIP_PROFILE_UPDATE", "0"},
      {"SHELL", "/bin/zsh"}
    ]

    assert {_, 0} = run_installer(fixture, environment)
    assert {_, 0} = run_installer(fixture, environment)

    path_line = ~s|export PATH="#{fixture.install_dir}:$PATH"|
    assert File.read!(profile_path) |> String.split("\n") |> Enum.count(&(&1 == path_line)) == 1
  end

  defp release_fixture(options) do
    root =
      Path.join(System.tmp_dir!(), "canaryd-install-test-#{System.unique_integer([:positive])}")

    release_dir = Path.join(root, "release")
    source_dir = Path.join(root, "source")
    install_dir = Path.join(root, "install")
    File.mkdir_p!(release_dir)
    File.mkdir_p!(source_dir)

    executable = Path.join(source_dir, "canaryd")
    File.write!(executable, "#!/bin/sh\necho 'canaryd 0.2.0'\n")
    File.chmod!(executable, 0o755)

    archive = Path.join(release_dir, @asset)
    {_, 0} = System.cmd("tar", ["-C", source_dir, "-czf", archive, "canaryd"])

    checksum =
      if options[:valid_checksum?] do
        archive |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      else
        String.duplicate("0", 64)
      end

    File.write!(Path.join(release_dir, "checksums-sha256.txt"), "#{checksum}  #{@asset}\n")
    on_exit(fn -> File.rm_rf(root) end)

    %{release_url: "file://#{release_dir}", install_dir: install_dir}
  end

  defp run_installer(fixture, extra_environment \\ []) do
    environment =
      Map.new([
        {"CANARYD_ARCH", "arm64"},
        {"CANARYD_INSTALL_DIR", fixture.install_dir},
        {"CANARYD_RELEASE_URL", fixture.release_url},
        {"CANARYD_SKIP_PROFILE_UPDATE", "1"}
      ])
      |> Map.merge(Map.new(extra_environment))
      |> Map.to_list()

    System.cmd("bash", [@script_path],
      env: environment,
      stderr_to_stdout: true
    )
  end
end
