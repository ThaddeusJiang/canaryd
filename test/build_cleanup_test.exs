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
    assert result.skipped == %{xcode: :active_build, rust: :active_build}
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
    assert result.skipped == %{xcode: :process_scan_unavailable, rust: :process_scan_unavailable}
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
    {:ok, lock} = File.open(lock_path, [:write, :exclusive])

    on_exit(fn -> File.close(lock) end)

    assert {:error, :locked} =
             BuildCleanup.run(
               home: root,
               rust_roots: [],
               lock_path: lock_path,
               process_scanner: fn -> {:ok, MapSet.new()} end
             )
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

  defp run(root, options) do
    options =
      Keyword.merge(
        [
          home: root,
          lock_path: Path.join(root, "cleanup.lock"),
          process_scanner: fn -> {:ok, MapSet.new()} end
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
