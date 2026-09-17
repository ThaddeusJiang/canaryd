defmodule Canaryd.RuntimePathsTest do
  use ExUnit.Case, async: false

  alias Canaryd.{BuildCleanup, CLI, Paths, Store}

  import ExUnit.CaptureIO
  alias Canaryd.Apps.CleanClip

  setup do
    original_home = System.get_env("HOME")

    runtime_home =
      Path.join("/private/tmp", "canaryd-runtime-home-#{System.unique_integer([:positive])}")

    System.put_env("HOME", runtime_home)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    %{runtime_home: runtime_home}
  end

  test "clean removes eligible backup, temporary and Bazel caches with bounded CLI history", %{
    runtime_home: home
  } do
    workspace = Path.join(home, "removed-worktree")
    hash = :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower)
    candidate = Path.join([home, "Library", "Caches", "bazel", "_bazel_test", hash])
    File.mkdir_p!(candidate)
    File.write!(Path.join(candidate, "DO_NOT_BUILD_HERE"), workspace)
    File.write!(Path.join(candidate, "lock"), "")
    File.write!(Path.join(candidate, "artifact"), "reproducible output")
    backup = Path.join([home, ".codex", "workspace-backups", "task"])
    target = Path.join(backup, "target")
    File.mkdir_p!(target)
    File.write!(Path.join(target, ".rustc_info.json"), "{}")

    File.write!(
      Path.join(target, "CACHEDIR.TAG"),
      "Signature: 8a477f597d28d172789f06886806bc55\n# cache directory tag created by cargo\n"
    )

    File.write!(Path.join(target, "artifact"), "rust output")
    File.write!(Path.join(backup, "unmerged.diff"), "keep")

    temporary_root = Path.join(home, ".rust-tmp")
    temporary_target = Path.join(temporary_root, "temporary-target")
    File.mkdir_p!(temporary_target)
    File.cp!(Path.join(target, "CACHEDIR.TAG"), Path.join(temporary_target, "CACHEDIR.TAG"))

    File.cp!(
      Path.join(target, ".rustc_info.json"),
      Path.join(temporary_target, ".rustc_info.json")
    )

    File.write!(Path.join(temporary_target, "artifact"), "temporary rust output")
    File.write!(Path.join(temporary_root, "source.rs"), "keep")

    cache_root = Path.join([Path.dirname(candidate), "cache", "repos", "v1"])
    download = Path.join([cache_root, "content_addressable", "sha256", String.duplicate("a", 64)])
    File.mkdir_p!(download)
    File.write!(Path.join(download, "file"), "downloaded dependency")

    contents = Path.join([cache_root, "contents", String.duplicate("b", 64)])
    repository = "00000000-0000-4000-8000-000000000001"
    File.mkdir_p!(Path.join(contents, repository))
    File.write!(Path.join(contents, repository <> ".recorded_inputs"), "repository inputs")
    File.write!(Path.join([contents, repository, "artifact"]), "extracted dependency")
    on_exit(fn -> File.rm_rf(home) end)

    output =
      capture_io(fn ->
        CLI.main(["clean"],
          ensure_notification_helper: fn -> :ok end,
          build_cleanup: fn ->
            BuildCleanup.run(
              now: ~U[2030-01-01 00:00:00Z],
              rust_tmp_root: temporary_root,
              rust_activity_scanner: fn -> {:ok, %{paths: [], names: MapSet.new()}} end,
              process_scanner: fn -> {:ok, MapSet.new()} end,
              bazel_activity_scanner: fn -> {:ok, %{pids: MapSet.new()}} end
            )
          end
        )
      end)

    assert output =~ "removed bazel: #{candidate}"
    assert output =~ "removed rust: #{target}"
    assert output =~ "removed rust: #{temporary_target}"
    assert output =~ "removed bazel_repository: #{download}"
    assert output =~ "removed bazel_repository: #{contents}"
    assert output =~ "failures=0"
    refute File.exists?(candidate)
    refute File.exists?(target)
    refute File.exists?(temporary_target)
    refute File.exists?(download)
    refute File.exists?(contents)
    assert File.read!(Path.join(backup, "unmerged.diff")) == "keep"
    assert File.read!(Path.join(temporary_root, "source.rs")) == "keep"
    assert File.regular?(Path.join([cache_root, "contents", "gc_lock"]))

    Store.with_tables(fn _, events ->
      assert [event] = Store.list_events(events, :builds)
      assert event.type == :cleanup_completed
      assert event.removed == 5
      assert event.reclaimed_bytes > 0
      assert event.bazel_skip == nil
      assert event.bazel_repository_skip == nil
      refute inspect(event) =~ home
    end)
  end

  test "resolves every user-specific path from the runtime home", %{runtime_home: runtime_home} do
    assert Paths.home_dir() == runtime_home

    assert Store.dir() ==
             Path.join([runtime_home, "Library", "Application Support", "canaryd"])

    assert Paths.launch_agents_dir() == Path.join([runtime_home, "Library", "LaunchAgents"])

    assert Paths.simulator_devices_dir() ==
             Path.join([runtime_home, "Library", "Developer", "CoreSimulator", "Devices"])

    assert Paths.clean_clip_store_path() ==
             Path.join([
               runtime_home,
               "Library",
               "Application Support",
               "CleanClip",
               "Storage.sqlite"
             ])

    assert CleanClip.history_dir() ==
             Path.join([
               runtime_home,
               "Library",
               "Application Support",
               "com.antiless.cleanclip.mac",
               "PrivateData",
               "HistoryItemContents"
             ])
  end
end
