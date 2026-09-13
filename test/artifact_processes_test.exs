defmodule Canaryd.ArtifactProcessesTest do
  use ExUnit.Case, async: true

  alias Canaryd.ArtifactProcesses

  setup do
    root =
      Path.join(
        "/private/tmp",
        "canaryd-artifact-processes-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "keeps complete process paths with spaces and resolves launch symlinks", %{root: root} do
    executable = executable(Path.join(root, "target with spaces/debug/custom-service"))
    launch_alias = Path.join(root, "launch alias")
    File.ln_s!(executable, launch_alias)

    runner = fn
      "/usr/bin/id", ["-u"] ->
        {:ok, "501\n"}

      "/bin/ps", ["-ww", "-U", "501", "-o", "pid=,stat=,comm="] ->
        {:ok, "  123 S #{launch_alias}\n"}
    end

    assert {:ok, snapshot} = ArtifactProcesses.scan(runner)

    assert ArtifactProcesses.activity(Path.join(root, "target with spaces"), snapshot) ==
             :active_target

    assert ArtifactProcesses.activity(Path.join(root, "target with spaces-idle"), snapshot) ==
             :idle
  end

  test "relative launch aliases inspect only those PIDs and only text mappings", %{root: root} do
    executable = executable(Path.join(root, "target/debug/renamed-server"))

    runner = fn
      "/usr/bin/id", ["-u"] ->
        {:ok, "501\n"}

      "/bin/ps", ["-ww", "-U", "501", "-o", "pid=,stat=,comm="] ->
        {:ok, "123 S ./launch-alias\n124 S /bin/sleep\n"}

      "/usr/sbin/lsof", ["-nP", "-a", "-p", "123", "-d", "txt", "-Fpn"] ->
        {:ok, "p123\nftxt\nn#{executable}\n"}
    end

    assert {:ok, snapshot} = ArtifactProcesses.scan(runner)
    assert ArtifactProcesses.activity(Path.join(root, "target"), snapshot) == :active_target
  end

  test "normalizes the macOS temporary-directory alias and requires a path boundary", %{
    root: root
  } do
    target = Path.join(root, "target")
    File.mkdir_p!(target)
    executable = executable(Path.join(target, "service"))
    alias_path = String.replace_prefix(executable, "/private/tmp/", "/tmp/")

    runner = fn
      "/usr/bin/id", ["-u"] -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "123 S #{alias_path}\n"}
    end

    assert {:ok, snapshot} = ArtifactProcesses.scan(runner)
    assert ArtifactProcesses.activity(target, snapshot) == :active_target
    assert ArtifactProcesses.activity(target <> "-idle", snapshot) == :idle
  end

  test "unresolved names protect only matching candidate executables", %{root: root} do
    target = Path.join(root, "target")
    executable(Path.join(target, "debug/custom-server"))
    File.write!(Path.join(target, "node"), "not executable")

    assert ArtifactProcesses.activity(target, %{paths: [], names: MapSet.new(["custom-server"])}) ==
             :active_target

    assert ArtifactProcesses.activity(target, %{paths: [], names: MapSet.new(["node"])}) == :idle
  end

  test "failed or incomplete process inspection is never idle", %{root: root} do
    target = Path.join(root, "target")
    File.mkdir_p!(target)

    for result <- [{:error, :timeout}, {:ok, ""}, {:ok, "p999\nn/bin/sleep\n"}] do
      runner = fn
        "/usr/bin/id", ["-u"] ->
          {:ok, "501\n"}

        "/bin/ps", ["-ww", "-U", "501", "-o", "pid=,stat=,comm="] ->
          {:ok, "123 S ./launch-alias\n"}

        "/usr/sbin/lsof", _ ->
          result
      end

      assert ArtifactProcesses.scan(runner) == {:error, :unavailable}
    end
  end

  test "rejects malformed process output" do
    runner = fn
      "/usr/bin/id", ["-u"] -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "not a process row\n"}
    end

    assert ArtifactProcesses.scan(runner) == {:error, :unavailable}
  end

  test "zombie processes do not require executable mappings" do
    runner = fn
      "/usr/bin/id", ["-u"] -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "123 S /bin/sleep\n124 Z <defunct>\n"}
    end

    assert {:ok, %{names: names}} = ArtifactProcesses.scan(runner)
    assert MapSet.size(names) == 0
  end

  defp executable(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "executable fixture")
    File.chmod!(path, 0o755)
    path
  end
end
