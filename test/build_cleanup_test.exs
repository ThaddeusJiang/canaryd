defmodule Canaryd.BuildCleanupTest do
  use ExUnit.Case, async: true

  alias Canaryd.{BuildCleanup, Duration}

  @cargo_tag """
  Signature: 8a477f597d28d172789f06886806bc55
  # This file is a cache directory tag created by cargo.
  """

  setup do
    root =
      Path.join(System.tmp_dir!(), "canaryd-build-cleanup-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "uses a fixed seven-day retention" do
    assert BuildCleanup.retention() == Duration.days(7)
  end

  test "daily discovery removes stale backup targets but preserves the backup and recent outputs",
       %{root: root} do
    backup =
      Path.join([root, ".codex", "workspace-backups", "mem-cleanup", "local-files", "task"])

    stale = cargo_target(Path.join([backup, "nmem-rs", "target"]))
    recent = cargo_target(Path.join([backup, "another-project", "target"]))
    File.touch!(Path.join(recent, "debug/app"), {{2029, 12, 31}, {23, 0, 0}})
    protected = Path.join(backup, "unmerged.diff")
    File.write!(protected, "unmerged source changes")
    File.write!(Path.join(backup, "preserved-files.tar.gz"), "backup archive")

    result = run(root, now: ~U[2030-01-01 00:00:00Z])

    assert Enum.map(result.removed, & &1.path) == [stale]
    refute File.exists?(stale)
    assert File.dir?(recent)
    assert File.read!(protected) == "unmerged source changes"
    assert File.read!(Path.join(backup, "preserved-files.tar.gz")) == "backup archive"
  end

  test "backup cleanup protects active Rust builds", %{root: root} do
    candidate = cargo_target(Path.join([root, ".codex", "workspace-backups", "task", "target"]))

    result =
      run(root,
        now: ~U[2030-01-01 00:00:00Z],
        process_scanner: fn -> {:ok, MapSet.new(["cargo"])} end
      )

    assert result.removed == []
    assert result.skipped.rust == :active_build
    assert File.dir?(candidate)
  end

  test "removes read-only backup directories and preserves external hard links", %{root: root} do
    target = cargo_target(Path.join([root, ".codex", "workspace-backups", "task", "target"]))
    artifact = Path.join(target, "debug/app")
    external = Path.join(root, "shared-artifact")
    File.chmod!(artifact, 0o444)
    File.ln!(artifact, external)
    File.chmod!(Path.join(target, "debug"), 0o555)
    on_exit(fn -> File.chmod(Path.join(target, "debug"), 0o755) end)

    result = run(root, now: ~U[2030-01-01 00:00:00Z])
    assert [%{kind: :rust, path: ^target}] = result.removed
    assert result.failures == []
    assert File.read!(external) == "rust build artifact"
    assert Bitwise.band(File.stat!(external).mode, 0o777) == 0o444
  end

  test "retains a backup target that becomes recent during process revalidation", %{root: root} do
    target = cargo_target(Path.join([root, ".codex", "workspace-backups", "task", "target"]))

    scanner = fn ->
      scans = Process.get(:backup_recent_scans, 0)
      Process.put(:backup_recent_scans, scans + 1)
      if scans == 1, do: File.touch!(Path.join(target, "debug/app"), {{2029, 12, 31}, {23, 0, 0}})
      {:ok, MapSet.new()}
    end

    assert run(root, now: ~U[2030-01-01 00:00:00Z], process_scanner: scanner).removed == []
    assert File.dir?(target)
  end

  test "does not discover backup targets through a symlinked Codex directory", %{root: root} do
    actual = Path.join(root, ".elsewhere")
    target = cargo_target(Path.join([actual, "workspace-backups", "task", "target"]))
    File.ln_s!(actual, Path.join(root, ".codex"))

    assert run(root, now: ~U[2030-01-01 00:00:00Z]).removed == []
    assert File.dir?(target)
  end

  test "revalidates backup ancestry after the process scan", %{root: root} do
    backup = Path.join([root, ".codex", "workspace-backups"])
    target = cargo_target(Path.join([backup, "task", "target"]))
    outside = Path.join(root, ".protected-backup")

    scanner = fn ->
      scans = Process.get(:backup_scans, 0)
      Process.put(:backup_scans, scans + 1)

      if scans == 1 do
        File.rename!(backup, outside)
        File.ln_s!(outside, backup)
      end

      {:ok, MapSet.new()}
    end

    assert run(root, now: ~U[2030-01-01 00:00:00Z], process_scanner: scanner).removed == []
    assert File.dir?(target)
  end

  test "discovers only validated Cargo target directories without following symlinks", %{
    root: root
  } do
    projects = Path.join(root, "Projects")
    cargo_target = cargo_target(Path.join(projects, "safe-target"))

    generic_cache = Path.join(projects, "generic-cache")
    File.mkdir_p!(generic_cache)
    File.write!(Path.join(generic_cache, "CACHEDIR.TAG"), @cargo_tag)

    missing_tag = Path.join(projects, "missing-tag")
    File.mkdir_p!(missing_tag)
    File.write!(Path.join(missing_tag, ".rustc_info.json"), "{}")

    symlink = Path.join(projects, "linked-target")
    File.ln_s!(cargo_target, symlink)

    assert BuildCleanup.rust_candidates([projects]) == [cargo_target]
  end

  test "rejects oversized Cargo markers in backups", %{root: root} do
    target = cargo_target(Path.join([root, ".codex", "workspace-backups", "task", "target"]))
    File.write!(Path.join(target, "CACHEDIR.TAG"), @cargo_tag <> String.duplicate("x", 4097))
    assert run(root, now: ~U[2030-01-01 00:00:00Z]).removed == []
    assert File.dir?(target)
  end

  test "Cargo discovery never enters a different filesystem", %{root: root} do
    local = cargo_target(Path.join([root, "Projects", "app", "target"]))
    mounted = Path.join(root, "Mounted")
    cargo_target(Path.join(mounted, "target"))

    reader = fn path ->
      refute String.starts_with?(path, mounted <> "/"), "must not inspect mounted children"

      case File.lstat(path) do
        {:ok, info} when path == mounted -> {:ok, %{info | major_device: info.major_device + 1}}
        result -> result
      end
    end

    assert BuildCleanup.rust_candidates([Path.join(root, "Projects"), mounted],
             filesystem_root: root,
             stat_reader: reader
           ) == [local]

    assert BuildCleanup.rust_candidates([root], stat_reader: reader) == [local]
  end

  test "keeps recent trees and removes stale Xcode and Cargo candidates", %{root: root} do
    xcode_candidate = xcode_candidate(root, "CurrentProject")
    cargo_candidate = cargo_target(Path.join([root, "Projects", "app", "target"]))

    recent =
      run(root,
        now: DateTime.utc_now(),
        rust_roots: [Path.join(root, "Projects")]
      )

    assert recent.removed == []
    assert File.dir?(xcode_candidate)
    assert File.dir?(cargo_candidate)

    stale =
      run(root,
        now: ~U[2030-01-01 00:00:00Z],
        rust_roots: [Path.join(root, "Projects")]
      )

    assert Enum.map(stale.removed, &{&1.kind, &1.path}) == [
             {:xcode, xcode_candidate},
             {:rust, cargo_candidate}
           ]

    refute File.exists?(xcode_candidate)
    refute File.exists?(cargo_candidate)
    assert stale.reclaimed_bytes > 0
  end

  test "keeps a stale directory when one descendant is recent", %{root: root} do
    xcode_candidate = xcode_candidate(root, "PartiallyRecentProject")

    File.touch!(
      Path.join(xcode_candidate, "artifact.o"),
      {{2029, 12, 31}, {23, 0, 0}}
    )

    result = run(root, now: ~U[2030-01-01 00:00:00Z], rust_roots: [])

    assert result.removed == []
    assert File.dir?(xcode_candidate)
  end

  test "does not follow a DerivedData root symlink", %{root: root} do
    real_root = Path.join(root, "external-derived-data")
    protected_candidate = Path.join(real_root, "ProtectedProject")
    File.mkdir_p!(protected_candidate)
    File.write!(Path.join(protected_candidate, "artifact.o"), "keep")

    derived_data = Path.join([root, "Library", "Developer", "Xcode", "DerivedData"])
    File.mkdir_p!(Path.dirname(derived_data))
    File.ln_s!(real_root, derived_data)

    result = run(root, now: ~U[2030-01-01 00:00:00Z], rust_roots: [])

    assert result.removed == []
    assert File.dir?(protected_candidate)
  end

  test "skips each build class while its protected process is active", %{root: root} do
    xcode_candidate = xcode_candidate(root, "ProtectedProject")
    cargo_candidate = cargo_target(Path.join([root, "Projects", "protected", "target"]))

    result =
      run(root,
        now: ~U[2030-01-01 00:00:00Z],
        rust_roots: [Path.join(root, "Projects")],
        process_scanner: fn -> {:ok, MapSet.new(["xcodebuild", "cargo"])} end
      )

    assert result.removed == []
    assert result.skipped == %{xcode: :active_build, rust: :active_build, bazel: nil}
    assert File.dir?(xcode_candidate)
    assert File.dir?(cargo_candidate)
  end

  test "deletes nothing when process inspection is unavailable", %{root: root} do
    xcode_candidate = xcode_candidate(root, "UnknownProject")
    cargo_candidate = cargo_target(Path.join([root, "Projects", "unknown", "target"]))

    result =
      run(root,
        now: ~U[2030-01-01 00:00:00Z],
        rust_roots: [Path.join(root, "Projects")],
        process_scanner: fn -> {:error, :unavailable} end
      )

    assert result.removed == []

    assert result.skipped == %{
             xcode: :process_scan_unavailable,
             rust: :process_scan_unavailable,
             bazel: :process_scan_unavailable
           }

    assert File.dir?(xcode_candidate)
    assert File.dir?(cargo_candidate)
  end

  test "rechecks protected processes immediately before deletion", %{root: root} do
    cargo_candidate = cargo_target(Path.join([root, "Projects", "racing", "target"]))

    process_scanner = fn ->
      scans = Process.get(:build_cleanup_process_scans, 0)
      Process.put(:build_cleanup_process_scans, scans + 1)

      if scans == 0 do
        {:ok, MapSet.new()}
      else
        {:ok, MapSet.new(["cargo"])}
      end
    end

    result =
      run(root,
        now: ~U[2030-01-01 00:00:00Z],
        rust_roots: [Path.join(root, "Projects")],
        process_scanner: process_scanner
      )

    assert result.removed == []
    assert result.skipped.rust == :active_build
    assert File.dir?(cargo_candidate)
  end

  test "does not start a second cleanup while its lock is held", %{root: root} do
    lock_path = Path.join(root, "cleanup.lock")

    assert {:ok, _} =
             BuildCleanup.run(
               home: root,
               lock_path: lock_path,
               process_scanner: fn ->
                 assert {:error, :locked} = BuildCleanup.run(home: root, lock_path: lock_path)
                 {:ok, MapSet.new()}
               end
             )
  end

  test "an abandoned lock file does not block future daily cleanup", %{root: root} do
    File.write!(Path.join(root, "cleanup.lock"), "")
    assert run(root, rust_roots: []).failures == []
  end

  test "a terminated cleanup releases the lock for the next run", %{root: root} do
    parent = self()

    pid =
      spawn(fn ->
        BuildCleanup.run(
          home: root,
          lock_path: Path.join(root, "cleanup.lock"),
          process_scanner: fn ->
            send(parent, :cleanup_locked)

            receive do
              :finish -> {:ok, MapSet.new()}
            end
          end
        )
      end)

    monitor = Process.monitor(pid)
    assert_receive :cleanup_locked, 1000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    # Port shutdown and the native child's EOF are asynchronous.
    Process.sleep(100)
    assert run(root, rust_roots: []).failures == []
  end

  test "parses protected process names from command paths" do
    output = """
    /Applications/Xcode.app/Contents/MacOS/Xcode
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
    /usr/local/bin/cargo
    /usr/local/bin/rustc
    /usr/bin/unrelated
    """

    assert BuildCleanup.parse_process_names(output) ==
             MapSet.new(["xcode", "xcodebuild", "cargo", "rustc", "unrelated"])
  end

  test "removes orphaned Bazel output bases even when recent, retaining live workspaces and shared caches",
       %{root: root} do
    orphan = bazel_cache(root, Path.join(root, "deleted-worktree"))
    workspace = Path.join(root, "existing-worktree")
    File.mkdir_p!(workspace)
    retained = bazel_cache(root, workspace)
    shared = Path.join(Path.dirname(orphan), "cache")
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, "artifact"), "keep")

    result = run(root, rust_roots: [])

    assert [%{kind: :bazel, path: ^orphan, bytes: bytes}] = result.removed
    assert bytes > 0
    refute File.exists?(orphan)
    assert File.dir?(retained)
    assert File.read!(Path.join(shared, "artifact")) == "keep"
  end

  test "protects only the Bazel cache used by a resident server", %{root: root} do
    busy = bazel_cache(root, Path.join(root, "busy-worktree"))
    idle = bazel_cache(root, Path.join(root, "idle-worktree"))
    File.mkdir_p!(Path.join(busy, "server"))
    File.write!(Path.join(busy, "server/server.pid.txt"), "1234")

    result =
      run(root,
        rust_roots: [],
        process_scanner: fn -> {:ok, MapSet.new(["bazel(busy-worktree)"])} end,
        bazel_activity_scanner: fn -> {:ok, %{pids: MapSet.new([1234])}} end
      )

    assert Enum.map(result.removed, & &1.path) == [idle]
    assert File.dir?(busy)
    assert result.skipped.bazel == :active_cache
  end

  test "protects a cache with a held native lock even without a server PID", %{root: root} do
    candidate = bazel_cache(root, Path.join(root, "deleted-worktree"))

    assert :protected =
             Canaryd.BazelCache.with_lock(candidate, fn ->
               result = run(root, rust_roots: [])
               assert result.removed == []
               assert result.skipped.bazel == :active_cache
               assert File.dir?(candidate)
               :protected
             end)
  end

  test "retains Bazel caches when activity inspection fails or a client is starting", %{
    root: root
  } do
    candidate = bazel_cache(root, Path.join(root, "deleted-worktree"))
    result = run(root, rust_roots: [], bazel_activity_scanner: fn -> {:error, :unavailable} end)
    assert result.skipped.bazel == :process_scan_unavailable
    assert File.dir?(candidate)

    result = run(root, rust_roots: [], process_scanner: fn -> {:ok, MapSet.new(["bazelisk"])} end)
    assert result.skipped.bazel == :active_build
    assert File.dir?(candidate)
  end

  test "rechecks a missing workspace after scanning activity", %{root: root} do
    workspace = Path.join(root, "recreated-worktree")
    candidate = bazel_cache(root, workspace)

    result =
      run(root,
        rust_roots: [],
        bazel_activity_scanner: fn ->
          File.mkdir_p!(workspace)
          {:ok, %{pids: MapSet.new()}}
        end
      )

    assert result.removed == []
    assert File.dir?(candidate)
  end

  test "removes read-only Bazel directories without following their artifact symlinks", %{
    root: root
  } do
    candidate = bazel_cache(root, Path.join(root, "deleted-worktree"))
    protected = Path.join(root, "protected-source")
    File.mkdir_p!(protected)
    File.write!(Path.join(protected, "source"), "keep")
    File.ln_s!(protected, Path.join(candidate, "execroot/source"))
    File.chmod!(Path.join(candidate, "execroot"), 0o555)

    result = run(root, rust_roots: [])
    assert [%{kind: :bazel, path: ^candidate}] = result.removed
    assert result.failures == []
    assert File.read!(Path.join(protected, "source")) == "keep"
  end

  test "rechecks Bazel activity while holding the lock before removal", %{root: root} do
    candidate = bazel_cache(root, Path.join(root, "deleted-worktree"))

    File.mkdir_p!(Path.join(candidate, "server"))
    File.write!(Path.join(candidate, "server/server.pid.txt"), "1234")

    result =
      run(root,
        rust_roots: [],
        bazel_activity_scanner: fn ->
          scans = Process.get(:bazel_activity_scans, 0)
          Process.put(:bazel_activity_scans, scans + 1)
          pids = if scans < 2, do: [], else: [1234]
          {:ok, %{pids: MapSet.new(pids)}}
        end
      )

    assert result.removed == []
    assert result.skipped.bazel == :active_cache
    assert File.dir?(candidate)
  end

  test "read-only artifact hard links retain their permissions outside a removed cache", %{
    root: root
  } do
    candidate = bazel_cache(root, Path.join(root, "deleted-worktree"))
    protected = Path.join(root, "shared-artifact")
    File.write!(protected, "keep")
    File.chmod!(protected, 0o444)
    File.ln!(protected, Path.join(candidate, "execroot/hardlink"))
    before_mode = File.stat!(protected).mode
    result = run(root, rust_roots: [])
    assert [%{kind: :bazel, path: ^candidate}] = result.removed
    assert File.stat!(protected).mode == before_mode
    assert File.read!(protected) == "keep"
  end

  defp bazel_cache(root, workspace) do
    hash = :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower)
    path = Path.join([root, "Library", "Caches", "bazel", "_bazel_test", hash])
    File.mkdir_p!(Path.join(path, "execroot"))
    File.write!(Path.join(path, "DO_NOT_BUILD_HERE"), workspace)
    File.write!(Path.join(path, "lock"), "")
    File.write!(Path.join(path, "execroot/artifact"), "reproducible output")
    path
  end

  defp run(root, options) do
    options =
      Keyword.merge(
        [
          home: root,
          lock_path: Path.join(root, "cleanup.lock"),
          process_scanner: fn -> {:ok, MapSet.new()} end,
          bazel_activity_scanner: fn -> {:ok, %{pids: MapSet.new()}} end
        ],
        options
      )

    assert {:ok, result} = BuildCleanup.run(options)
    result
  end

  defp xcode_candidate(root, name) do
    path = Path.join([root, "Library", "Developer", "Xcode", "DerivedData", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "artifact.o"), "xcode build artifact")
    path
  end

  defp cargo_target(path) do
    File.mkdir_p!(Path.join(path, "debug"))
    File.write!(Path.join(path, "CACHEDIR.TAG"), @cargo_tag)
    File.write!(Path.join(path, ".rustc_info.json"), "{}")
    File.write!(Path.join(path, "debug/app"), "rust build artifact")
    path
  end
end
