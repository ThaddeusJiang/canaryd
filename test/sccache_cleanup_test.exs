defmodule Canaryd.SccacheCleanupTest do
  use ExUnit.Case, async: true
  alias Canaryd.SccacheCleanup

  setup do
    home = Path.join("/private/tmp", "canaryd-sccache-#{System.unique_integer([:positive])}")
    root = Path.join(home, "Library/Caches/Mozilla.sccache")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home, root: root}
  end

  test "evicts only old digest objects, retaining recent and unknown files", c do
    old = object(c.root, "aa", 1)
    recent = object(c.root, "bb", 2)
    unknown = Path.join(c.root, "preprocessor")
    File.write!(unknown, "keep")
    result = run(c.home)
    assert result.removed_objects == 1
    assert result.reclaimed_bytes == 5
    refute File.exists?(old)
    assert File.exists?(recent)
    assert File.exists?(unknown)
  end

  test "retains objects accessed after the cutoff", c do
    path = object(c.root, "aa", 1)
    {:ok, s} = File.stat(path, time: :posix)
    File.write_stat!(path, %{s | atime: 2}, time: :posix)
    assert run(c.home).removed_objects == 0
  end

  test "does not follow bucket or object symlinks", c do
    outside = Path.join(c.home, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(c.root, "a"))
    path = object(c.root, "bb", 1)
    File.rm!(path)
    File.write!(Path.join(outside, "data"), "keep")
    File.ln_s!(Path.join(outside, "data"), path)
    assert run(c.home).removed_objects == 0
    assert File.read!(Path.join(outside, "data")) == "keep"
  end

  test "active builds and unavailable inspection fail closed", c do
    path = object(c.root, "aa", 1)

    for reason <- [:active_build, :process_scan_unavailable] do
      assert run(c.home, activity_scanner: fn -> {:error, reason} end).skipped == reason
      assert File.exists?(path)
    end
  end

  test "keeps open objects and rechecks activity before deletion", c do
    path = object(c.root, "aa", 1)
    assert run(c.home, activity_scanner: fn -> {:ok, MapSet.new([path])} end).removed_objects == 0
    counter = :counters.new(1, [])

    scan = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) > 1, do: {:error, :active_build}, else: {:ok, MapSet.new()}
    end

    assert run(c.home, activity_scanner: scan).skipped == :active_build
    assert File.exists?(path)
  end

  test "revalidates timestamp after activity inspection", c do
    path = object(c.root, "aa", 1)

    scan = fn ->
      File.touch!(path)
      {:ok, MapSet.new()}
    end

    assert run(c.home, activity_scanner: scan).removed_objects == 0
    assert File.exists?(path)
  end

  test "limits work and reports partial progress", c do
    object(c.root, "aa", 1)
    object(c.root, "bb", 1)
    result = run(c.home, max_objects: 1)
    assert result.removed_objects == 1
    assert result.skipped == :budget_exhausted
  end

  test "scanner blocks compiler processes and fails closed on missing server inspection" do
    runner = fn
      "/usr/bin/id", _ -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "42 /opt/homebrew/bin/clang++\n"}
    end

    assert {:error, :active_build} = SccacheCleanup.scan_activity(runner)

    runner = fn
      "/usr/bin/id", _ -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "42 /opt/homebrew/bin/sccache\n"}
      "/usr/sbin/lsof", _ -> {:error, :timeout}
    end

    assert {:error, :process_scan_unavailable} = SccacheCleanup.scan_activity(runner)
  end

  test "scanner preserves open object paths and checks every server PID" do
    runner = fn
      "/usr/bin/id", _ -> {:ok, "501\n"}
      "/bin/ps", _ -> {:ok, "42 /opt/homebrew/bin/sccache\n"}
      "/usr/sbin/lsof", _ -> {:ok, "p42\nf3\nn/Users/test/cache object\n"}
    end

    assert {:ok, paths} = SccacheCleanup.scan_activity(runner)
    assert MapSet.member?(paths, "/Users/test/cache object")
  end

  test "expired time budget retains objects", c do
    path = object(c.root, "aa", 1)
    assert run(c.home, budget: 0).skipped == :budget_exhausted
    assert File.exists?(path)
  end

  defp run(home, options \\ []) do
    SccacheCleanup.run(
      home,
      1,
      Keyword.merge([activity_scanner: fn -> {:ok, MapSet.new()} end], options)
    )
  end

  defp object(root, prefix, timestamp) do
    [a, b] = String.graphemes(prefix)
    path = Path.join([root, a, b, prefix <> String.duplicate("0", 62)])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "cache")
    {:ok, stat} = File.stat(path, time: :posix)
    File.write_stat!(path, %{stat | mtime: timestamp, atime: timestamp}, time: :posix)
    path
  end
end
