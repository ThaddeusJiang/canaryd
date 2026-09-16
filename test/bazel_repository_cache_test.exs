defmodule Canaryd.BazelRepositoryCacheTest do
  use ExUnit.Case, async: true

  alias Canaryd.{BazelCache, BazelRepositoryCache, Duration, FileLock}

  @old 1_600_000_000
  @cutoff 1_700_000_000
  @uuid "12345678-1234-4123-8123-123456789abc"

  setup do
    temp = System.tmp_dir!() |> String.replace_prefix("/var/", "/private/var/")
    home = Path.join(temp, "canaryd-repos-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home}
  end

  test "expires old hashes despite recent siblings and preserves cache roots", %{home: home} do
    old = download(home, "sha256", String.duplicate("a", 64))
    recent = download(home, "sha256", String.duplicate("b", 64))
    File.touch!(Path.join(recent, "file"))
    contents = contents(home, "c")
    recent_contents = contents(home, "d")
    File.touch!(Path.join(recent_contents, @uuid <> ".recorded_inputs"))
    result = run(home)
    assert Enum.sort(Enum.map(result.removed, & &1.path)) == Enum.sort([old, contents])
    assert Enum.all?(result.removed, &(&1.kind == :bazel_repository))
    assert result.reclaimed_bytes > 0
    assert File.dir?(recent)
    assert File.dir?(recent_contents)
    assert File.dir?(Path.dirname(old))
    assert File.regular?(Path.join(repos(home), "contents/gc_lock"))
  end

  test "accepts official digest lengths and keeps unknown or incomplete downloads", %{home: home} do
    valid =
      for {algorithm, size} <- [
            {"sha1", 40},
            {"sha256", 64},
            {"sha384", 96},
            {"sha512", 128},
            {"blake3", 64}
          ] do
        path = download(home, algorithm, String.duplicate("A", size))
        File.write!(Path.join(path, "id-" <> String.duplicate("b", size)), "")
        age(path)
        path
      end

    invalid =
      for {algorithm, digest, extra} <- [
            {"md5", String.duplicate("a", 32), nil},
            {"sha256", String.duplicate("c", 40), nil},
            {"sha256", String.duplicate("d", 64), "tmp-download"},
            {"sha256", String.duplicate("e", 64), "id-bad"},
            {"sha256", String.duplicate("f", 64), "unknown"}
          ] do
        path = download(home, algorithm, digest)
        if extra, do: File.write!(Path.join(path, extra), "keep")
        age(path)
        path
      end

    assert Enum.sort(Enum.map(run(home).removed, & &1.path)) == Enum.sort(valid)
    assert Enum.all?(invalid, &File.dir?/1)
  end

  test "contents requires paired UUIDv4 directories and recorded inputs", %{home: home} do
    unpaired = contents(home, "a")
    File.rm!(Path.join(unpaired, @uuid <> ".recorded_inputs"))
    unknown = contents(home, "b")
    File.write!(Path.join(unknown, "unknown"), "keep")
    wrong_uuid = contents(home, "c")
    File.rename!(Path.join(wrong_uuid, @uuid), Path.join(wrong_uuid, "not-a-uuid"))
    for path <- [unpaired, unknown, wrong_uuid], do: age(path)
    assert run(home).removed == []
    assert Enum.all?([unpaired, unknown, wrong_uuid], &File.dir?/1)
  end

  test "existing workspace bases are locked without becoming orphan candidates", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))
    base = output_base(home, "existing")
    refute BazelCache.valid_candidate?(base, home)

    assert :ok =
             FileLock.with_lock(Path.join(base, "lock"), fn ->
               assert run(home).skipped == :active_cache
               assert File.dir?(path)
               :ok
             end)

    assert [%{path: ^path}] = run(home).removed
    assert File.dir?(base)
  end

  test "missing symlinked or malformed output-base locks and markers fail closed", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))
    base = output_base(home, "existing")
    lock = Path.join(base, "lock")
    File.rm!(lock)
    assert run(home).skipped == :unverifiable_cache
    File.ln_s!(Path.join(home, "missing"), lock)
    assert run(home).skipped == :unverifiable_cache
    File.rm!(lock)
    File.write!(lock, "")
    File.write!(Path.join(base, "DO_NOT_BUILD_HERE"), "relative")
    assert run(home).skipped == :unverifiable_cache
    assert File.dir?(path)
  end

  test "resident Bazel processes and live server PID protect shared downloads", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))

    for name <- ["bazel", "bazelisk", "bazel(workspace)"] do
      assert run(home, process_scanner: fn -> {:ok, MapSet.new([name])} end).skipped ==
               :active_build
    end

    base = output_base(home, "existing")
    File.mkdir_p!(Path.join(base, "server"))
    File.write!(Path.join(base, "server/server.pid.txt"), "42")

    assert run(home, activity_scanner: fn -> {:ok, %{pids: MapSet.new([42])}} end).skipped ==
             :active_cache

    assert File.dir?(path)
  end

  test "busy or symlinked contents gc lock protects contents and is never truncated", %{
    home: home
  } do
    path = contents(home, "a")
    lock = Path.join(Path.dirname(path), "gc_lock")
    File.write!(lock, "preserve lock contents")

    assert :ok =
             FileLock.with_lock(lock, fn ->
               assert run(home).skipped == :active_cache
               :ok
             end)

    assert File.read!(lock) == "preserve lock contents"
    File.rm!(lock)
    File.ln_s!(Path.join(home, "missing"), lock)
    assert run(home).skipped == :unverifiable_cache
    assert File.dir?(path)
  end

  test "runtime references preserve only the matching hash", %{home: home} do
    active = download(home, "sha256", String.duplicate("a", 64))
    idle = download(home, "sha256", String.duplicate("b", 64))
    snapshot = %{paths: [Path.join(active, "file")], names: MapSet.new()}
    result = run(home, runtime_scanner: fn -> {:ok, snapshot} end)
    assert [%{path: ^idle}] = result.removed
    assert result.skipped == :active_target
    assert File.dir?(active)

    assert run(home, runtime_scanner: fn -> {:error, :unavailable} end).skipped ==
             :process_scan_unavailable
  end

  test "revalidates age and newly created output bases after process callbacks", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))
    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 2, do: File.touch!(Path.join(path, "file"))
      {:ok, MapSet.new()}
    end

    assert run(home, process_scanner: scanner).removed == []
    assert File.dir?(path)

    age(path)
    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 2, do: output_base(home, "new-workspace")
      {:ok, MapSet.new()}
    end

    assert run(home, process_scanner: scanner).removed == []
    assert File.dir?(path)
  end

  test "rejects structural symlinks and keeps hardlink modes and linked payloads", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))
    file = Path.join(path, "file")
    source = Path.join(home, "shared-source")
    File.write!(source, "shared")
    File.rm!(file)
    File.ln!(source, file)
    File.chmod!(source, 0o444)
    age(path)

    tree = contents(home, "b")
    outside = Path.join(home, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep"), "keep")
    File.ln_s!(outside, Path.join(tree, @uuid <> "/link"))
    File.chmod!(Path.join(tree, @uuid), 0o555)
    age(tree)
    assert length(run(home).removed) == 2
    assert Bitwise.band(File.stat!(source).mode, 0o777) == 0o444
    assert File.read!(Path.join(outside, "keep")) == "keep"

    linked = download(home, "sha256", String.duplicate("c", 64))
    original = linked <> "-outside"
    File.rename!(linked, original)
    File.ln_s!(original, linked)
    assert run(home).removed == []
    assert File.dir?(original)
  end

  test "rechecks hash and lock identities after callbacks", %{home: home} do
    path = download(home, "sha256", String.duplicate("a", 64))
    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 2 do
        File.rename!(path, path <> "-moved")
        download(home, "sha256", String.duplicate("a", 64))
      end

      {:ok, MapSet.new()}
    end

    assert run(home, process_scanner: scanner).removed == []
    assert File.dir?(path)

    base = output_base(home, "existing")
    lock = Path.join(base, "lock")
    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 2 do
        File.rename!(lock, lock <> ".moved")
        File.write!(lock, "")
      end

      {:ok, MapSet.new()}
    end

    assert run(home, process_scanner: scanner).removed == []
    assert File.dir?(path)
  end

  test "rechecks contents gc lock identity and newly running clients", %{home: home} do
    path = contents(home, "a")
    lock = Path.join(Path.dirname(path), "gc_lock")
    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 2 do
        File.rename!(lock, lock <> ".moved")
        File.write!(lock, "")
      end

      {:ok, MapSet.new()}
    end

    assert run(home, process_scanner: scanner).removed == []
    assert File.dir?(path)

    counter = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(counter, 1, 1) == 1,
        do: {:ok, MapSet.new()},
        else: {:ok, MapSet.new(["bazel"])}
    end

    assert run(home, process_scanner: scanner).skipped == :active_build
    assert File.dir?(path)
  end

  test "caps eligible hashes at sixteen and releases output-base locks", %{home: home} do
    base = output_base(home, "existing")
    lock = Path.join(base, "lock")

    for index <- 1..17 do
      download(home, "sha256", Integer.to_string(index, 16) |> String.pad_leading(64, "0"))
    end

    recent = download(home, "sha256", String.duplicate("e", 64))
    File.touch!(Path.join(recent, "file"))
    invalid = download(home, "sha256", String.duplicate("f", 64))
    File.write!(Path.join(invalid, "unknown"), "keep")
    age(invalid)
    calls = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(calls, 1, 1) == 1 do
        assert {:error, :locked} = FileLock.with_lock(lock, fn -> flunk("base lock escaped") end)
      end

      {:ok, %{paths: [], names: MapSet.new()}}
    end

    result =
      run(home,
        runtime_scanner: scanner,
        order_candidates: fn entries -> entries |> Enum.sort() |> Enum.reverse() end
      )

    assert length(result.removed) == 16
    assert :atomics.get(calls, 1) == 32
    assert result.skipped == :budget_exhausted
    assert :released = FileLock.with_lock(lock, fn -> :released end)
    assert File.dir?(recent)
    assert File.dir?(invalid)
    assert length(run(home).removed) == 1
  end

  test "soft deadline completes one candidate and releases gc and output-base locks", %{
    home: home
  } do
    base = output_base(home, "existing")
    contents(home, "a")
    contents(home, "b")
    gc_lock = Path.join(repos(home), "contents/gc_lock")
    elapsed = :atomics.new(1, [])

    scanner = fn ->
      assert {:error, :locked} = FileLock.with_lock(gc_lock, fn -> flunk("gc lock escaped") end)
      :atomics.add(elapsed, 1, Duration.seconds(10))
      {:ok, %{paths: [], names: MapSet.new()}}
    end

    result = run(home, clock: fn -> :atomics.get(elapsed, 1) end, runtime_scanner: scanner)
    assert length(result.removed) == 1
    assert :atomics.get(elapsed, 1) == Duration.seconds(20)
    assert result.skipped == :budget_exhausted
    assert :released = FileLock.with_lock(gc_lock, fn -> :released end)
    assert :released = FileLock.with_lock(Path.join(base, "lock"), fn -> :released end)
  end

  test "candidate ordering lets subsequent rounds progress past an active hash", %{home: home} do
    active = download(home, "sha256", String.duplicate("a", 64))
    idle = contents(home, "b")
    snapshot = %{paths: [Path.join(active, "file")], names: MapSet.new()}
    options = [candidate_limit: 1, runtime_scanner: fn -> {:ok, snapshot} end]

    first = run(home, options ++ [order_candidates: &Enum.sort/1])
    assert first.removed == []
    assert first.skipped == :budget_exhausted

    second =
      run(
        home,
        options ++ [order_candidates: fn entries -> entries |> Enum.sort() |> Enum.reverse() end]
      )

    assert [%{path: ^idle}] = second.removed
    assert File.dir?(active)
  end

  test "new output base stops the entire batch and releases existing locks", %{home: home} do
    base = output_base(home, "existing")
    for char <- ["a", "b", "c"], do: download(home, "sha256", String.duplicate(char, 64))
    calls = :atomics.new(1, [])
    runtime = :atomics.new(1, [])

    scanner = fn ->
      if :atomics.add_get(calls, 1, 1) == 2, do: output_base(home, "new-workspace")
      {:ok, MapSet.new()}
    end

    result =
      run(home,
        process_scanner: scanner,
        runtime_scanner: fn ->
          :atomics.add(runtime, 1, 1)
          {:ok, %{paths: [], names: MapSet.new()}}
        end
      )

    assert result.removed == []
    assert result.skipped == :unverifiable_cache
    assert :atomics.get(calls, 1) == 2
    assert :atomics.get(runtime, 1) <= 1
    assert :released = FileLock.with_lock(Path.join(base, "lock"), fn -> :released end)
  end

  test "round deadline stops before taking locks for another user cache", %{home: home} do
    original = contents(home, "a")
    user_root = Path.join(home, "Library/Caches/bazel/_bazel_test")

    for name <- ["_bazel_second", "_bazel_third"] do
      copy = Path.join(Path.dirname(user_root), name)
      File.cp_r!(user_root, copy)
      age(copy)
    end

    elapsed = :atomics.new(1, [])
    calls = :atomics.new(1, [])

    scanner = fn ->
      :atomics.add(calls, 1, 1)
      :atomics.add(elapsed, 1, Duration.seconds(20))
      {:ok, %{paths: [], names: MapSet.new()}}
    end

    result = run(home, clock: fn -> :atomics.get(elapsed, 1) end, runtime_scanner: scanner)
    assert length(result.removed) == 2
    assert :atomics.get(calls, 1) == 4
    assert result.skipped == :budget_exhausted

    assert length(
             Path.wildcard(
               Path.join(
                 home,
                 "Library/Caches/bazel/_bazel_*/cache/repos/v1/contents/" <>
                   Path.basename(original)
               )
             )
           ) == 1
  end

  defp run(home, options \\ []) do
    defaults = [
      process_scanner: fn -> {:ok, MapSet.new()} end,
      activity_scanner: fn -> {:ok, %{pids: MapSet.new()}} end,
      runtime_scanner: fn -> {:ok, %{paths: [], names: MapSet.new()}} end
    ]

    BazelRepositoryCache.run(home, @cutoff, Keyword.merge(defaults, options))
  end

  defp repos(home), do: Path.join(home, "Library/Caches/bazel/_bazel_test/cache/repos/v1")

  defp download(home, algorithm, digest) do
    path = Path.join([repos(home), "content_addressable", algorithm, digest])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "file"), "cached download")
    age(path)
    path
  end

  defp contents(home, char) do
    path = Path.join([repos(home), "contents", String.duplicate(char, 64)])
    File.mkdir_p!(Path.join(path, @uuid))
    File.write!(Path.join(path, @uuid <> "/BUILD"), "repository payload")
    File.write!(Path.join(path, @uuid <> ".recorded_inputs"), "recorded inputs")
    age(path)
    path
  end

  defp output_base(home, name) do
    workspace = Path.join(home, name)
    File.mkdir_p!(workspace)
    hash = :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower)
    path = Path.join(home, "Library/Caches/bazel/_bazel_test/" <> hash)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "DO_NOT_BUILD_HERE"), workspace)
    File.write!(Path.join(path, "lock"), "")
    path
  end

  defp age(path) do
    if File.lstat!(path).type == :directory do
      Enum.each(File.ls!(path), &age(Path.join(path, &1)))
    end

    if File.lstat!(path).type == :symlink do
      {_, 0} = System.cmd("/usr/bin/touch", ["-h", "-t", "202009132026.40", path])
    else
      File.touch!(path, @old)
    end
  end
end
