defmodule Canaryd.BazelCacheTest do
  use ExUnit.Case, async: true

  alias Canaryd.BazelCache

  setup do
    home = Path.join(System.tmp_dir!(), "canaryd-bazel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home}
  end

  test "rejects missing, oversized, malformed, symlinked and mismatched workspace markers", %{
    home: home
  } do
    path = candidate(home, Path.join(home, "missing"))
    marker = Path.join(path, "DO_NOT_BUILD_HERE")
    assert BazelCache.candidates(home) == [path]

    for value <- [
          "",
          "relative/path",
          String.duplicate("x", 4097),
          <<255>>,
          "/Volumes/offline/project",
          Path.join(home, "different")
        ] do
      File.write!(marker, value)
      assert BazelCache.candidates(home) == []
    end

    File.rm!(marker)
    assert BazelCache.candidates(home) == []
    source = Path.join(home, "marker-source")
    File.write!(source, Path.join(home, "missing"))
    File.ln_s!(source, marker)
    assert BazelCache.candidates(home) == []
  end

  test "keeps workspaces on symlinked parents, including dangling symlinks", %{home: home} do
    parent = Path.join(home, "linked")
    File.ln_s!(Path.join(home, "unmounted"), parent)
    path = candidate(home, Path.join(parent, "project"))
    refute BazelCache.valid_candidate?(path, home)

    File.rm!(parent)
    File.mkdir_p!(Path.join(home, "destination"))
    File.ln_s!(Path.join(home, "destination"), parent)
    refute BazelCache.valid_candidate?(path, home)
  end

  test "keeps workspaces outside supported local roots even when absent", %{home: home} do
    path = candidate(home, "/Volumes/offline/project")
    refute BazelCache.valid_candidate?(path, home)
    other = candidate(home, home <> "-other/missing")
    refute BazelCache.valid_candidate?(other, home)
  end

  test "rejects symbolic links at the cache root, user root and output base", %{home: home} do
    path = candidate(home, Path.join(home, "missing"))

    for selected <- [path, Path.dirname(path), Path.join(home, "Library/Caches")] do
      moved = Path.join(home, "protected-original")
      File.rename!(selected, moved)
      File.ln_s!(moved, selected)
      assert BazelCache.candidates(home) == []
      refute BazelCache.valid_candidate?(path, home)
      File.rm!(selected)
      File.rename!(moved, selected)
    end
  end

  test "an existing non-directory workspace is not considered missing", %{home: home} do
    workspace = Path.join(home, "file")
    path = candidate(home, workspace)
    File.write!(workspace, "keep")
    refute BazelCache.valid_candidate?(path, home)
  end

  test "protects malformed server state but accepts a confirmed dead server PID", %{home: home} do
    path = candidate(home, Path.join(home, "missing"))
    server = Path.join(path, "server")
    File.mkdir_p!(server)
    pid_file = Path.join(server, "server.pid.txt")
    snapshot = %{pids: MapSet.new([23])}
    File.write!(pid_file, "23\n")
    assert BazelCache.activity(path, snapshot) == :active_cache
    File.write!(pid_file, "24\n")
    assert BazelCache.activity(path, snapshot) == :idle
    File.write!(pid_file, "not a pid")
    assert BazelCache.activity(path, snapshot) == :unverifiable_cache
    File.rm!(pid_file)
    File.ln_s!(Path.join(home, "absent-pid"), pid_file)
    assert BazelCache.activity(path, snapshot) == :unverifiable_cache
  end

  test "parses live PIDs and rejects failed or malformed inspection output" do
    assert {:ok, %{pids: pids}} =
             BazelCache.scan_activity(fn "/bin/ps", ["-axo", "pid="] -> {:ok, " 12\n 34\n"} end)

    assert pids == MapSet.new([12, 34])

    for output <- [{:error, :unavailable}, {:ok, ""}, {:ok, "ps: error"}] do
      assert {:error, :unavailable} = BazelCache.scan_activity(fn _, _ -> output end)
    end
  end

  test "native lock protects the entire callback and can be reacquired", %{home: home} do
    path = candidate(home, Path.join(home, "missing"))

    assert :done =
             BazelCache.with_lock(path, fn ->
               assert {:skip, :active_cache} =
                        BazelCache.with_lock(path, fn -> flunk("lock must be exclusive") end)

               :done
             end)

    assert :done = BazelCache.with_lock(path, fn -> :done end)
  end

  test "missing or symlinked native lock files never authorize removal", %{home: home} do
    path = candidate(home, Path.join(home, "missing"))
    lock = Path.join(path, "lock")
    File.rm!(lock)
    callback = fn -> flunk("unverifiable lock must not run cleanup") end
    assert {:skip, :unverifiable_cache} = BazelCache.with_lock(path, callback)
    File.ln_s!(Path.join(home, "absent-lock"), lock)
    assert {:skip, :unverifiable_cache} = BazelCache.with_lock(path, callback)
  end

  test "limits external command output and rejects failed commands" do
    assert {:ok, "501\n"} = BazelCache.command("/usr/bin/printf", ["501\n"])
    assert {:error, :unavailable} = BazelCache.command("/usr/bin/false", [])

    assert {:error, :output_limit} =
             BazelCache.command("/usr/bin/head", ["-c", "8388609", "/dev/zero"])
  end

  test "times out an unresponsive inspection command" do
    assert {:error, :timeout} = BazelCache.command("/bin/sleep", ["10"])
  end

  defp candidate(home, workspace) do
    hash = :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower)
    path = Path.join([home, "Library", "Caches", "bazel", "_bazel_test", hash])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "DO_NOT_BUILD_HERE"), workspace)
    File.write!(Path.join(path, "lock"), "")
    path
  end
end
