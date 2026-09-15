defmodule Canaryd.BuildCleanup do
  @moduledoc """
  Removes stale Xcode/Cargo artifacts, orphaned Bazel output bases, and stale
  shared Bazel repository entries.

  Candidate discovery and process checks are intentionally conservative. A
  path is removed only after its identity and active build state have been
  revalidated, together with tree age or a missing workspace as appropriate.
  """

  alias Canaryd.{
    ArtifactProcesses,
    ArtifactTree,
    BazelCache,
    BazelRepositoryCache,
    BuildCleanupConfig,
    Duration,
    FileLock,
    Paths
  }

  @cargo_signature "Signature: 8a477f597d28d172789f06886806bc55"
  @cargo_marker "cache directory tag created by cargo"
  @marker_limit 4096
  @max_depth 12

  @xcode_processes MapSet.new(["simulator", "xcode", "xcodebuild", "xctest"])
  @rust_processes MapSet.new(["cargo", "rustc"])

  @excluded_home_entries MapSet.new([
                           "Applications",
                           "Library",
                           "Movies",
                           "Music",
                           "Pictures",
                           ".Trash",
                           ".codex"
                         ])

  @pruned_entries MapSet.new([
                    ".git",
                    ".gradle",
                    ".venv",
                    "DerivedData",
                    "Pods",
                    "_build",
                    "deps",
                    "node_modules",
                    "vendor"
                  ])

  @doc false
  def retention, do: BuildCleanupConfig.default_retention()

  @doc "Run one exclusive build cleanup round."
  def run(options \\ []) do
    home = Keyword.get(options, :home, Paths.home_dir())

    lock_path =
      Keyword.get(options, :lock_path, Path.join(Paths.support_dir(), "build-cleanup.lock"))

    File.mkdir_p!(Path.dirname(lock_path))

    FileLock.with_lock(
      lock_path,
      fn ->
        with {:ok, retention} <- BuildCleanupConfig.read(home) do
          {:ok, cleanup(home, retention, options)}
        end
      end,
      create: true
    )
  end

  @doc false
  def rust_candidates(roots, options \\ []) do
    stat_reader = Keyword.get(options, :stat_reader, &File.lstat/1)

    roots
    |> Enum.flat_map(fn root ->
      boundary = Keyword.get(options, :filesystem_root, root)

      case stat_reader.(boundary) do
        {:ok, %{type: :directory, major_device: device}} ->
          discover_rust_targets(root, 0, device, stat_reader)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def parse_process_names(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn command ->
      command
      |> String.trim()
      |> Path.basename()
      |> String.downcase()
    end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp cleanup(home, retention, options) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    process_scanner = Keyword.get(options, :process_scanner, &active_process_names/0)
    rust_roots = Keyword.get_lazy(options, :rust_roots, fn -> default_rust_roots(home) end)

    rust_context = %{
      home: home,
      tmp_root: Keyword.get(options, :rust_tmp_root, "/private/tmp"),
      stat_reader: Keyword.get(options, :stat_reader, &File.lstat/1),
      activity_scanner: Keyword.get(options, :rust_activity_scanner, &ArtifactProcesses.scan/0)
    }

    xcode_root = Path.join([home, "Library", "Developer", "Xcode", "DerivedData"])

    result = %{
      removed: [],
      reclaimed_bytes: 0,
      skipped: %{xcode: nil, rust: nil, bazel: nil, bazel_repository: nil},
      failures: []
    }

    case process_scanner.() do
      {:ok, process_names} ->
        cutoff =
          now
          |> Duration.add(-retention)
          |> DateTime.to_unix(:second)

        result
        |> cleanup_category(
          :xcode,
          xcode_candidates(xcode_root),
          xcode_root,
          cutoff,
          process_names,
          process_scanner
        )
        |> cleanup_category(
          :rust,
          rust_candidates(rust_roots,
            filesystem_root: home,
            stat_reader: rust_context.stat_reader
          ) ++
            temporary_rust_candidates(rust_context),
          rust_context,
          cutoff,
          process_names,
          process_scanner
        )
        |> cleanup_category(
          :bazel,
          BazelCache.candidates(home),
          %{
            home: home,
            activity_scanner:
              Keyword.get(options, :bazel_activity_scanner, &BazelCache.scan_activity/0)
          },
          nil,
          process_names,
          process_scanner
        )
        |> Map.update!(:removed, &Enum.reverse/1)
        |> Map.update!(:failures, &Enum.reverse/1)
        |> cleanup_repositories(home, cutoff, options)

      {:error, _reason} ->
        put_in(result.skipped, %{
          xcode: :process_scan_unavailable,
          rust: :process_scan_unavailable,
          bazel: :process_scan_unavailable,
          bazel_repository: :process_scan_unavailable
        })
    end
  end

  defp cleanup_repositories(result, home, cutoff, options) do
    repositories =
      BazelRepositoryCache.run(home, cutoff,
        process_scanner: Keyword.get(options, :process_scanner, &active_process_names/0),
        activity_scanner:
          Keyword.get(options, :bazel_activity_scanner, &BazelCache.scan_activity/0),
        runtime_scanner: Keyword.get(options, :rust_activity_scanner, &ArtifactProcesses.scan/0)
      )

    %{
      result
      | removed: result.removed ++ repositories.removed,
        reclaimed_bytes: result.reclaimed_bytes + repositories.reclaimed_bytes,
        failures: result.failures ++ repositories.failures,
        skipped: Map.put(result.skipped, :bazel_repository, repositories.skipped)
    }
  end

  defp cleanup_category(
         result,
         kind,
         candidates,
         validation_root,
         cutoff,
         process_names,
         process_scanner
       ) do
    if blocked?(kind, process_names) do
      put_in(result, [:skipped, kind], :active_build)
    else
      Enum.reduce_while(candidates, result, fn path, current ->
        case cleanup_candidate(kind, path, validation_root, cutoff, process_scanner) do
          {:removed, bytes} ->
            removed = %{kind: kind, path: path, bytes: bytes}

            {:cont,
             current
             |> Map.update!(:removed, &[removed | &1])
             |> Map.update!(:reclaimed_bytes, &(&1 + bytes))}

          :kept ->
            {:cont, current}

          {:skip, reason} ->
            {:cont, put_in(current, [:skipped, kind], reason)}

          {:error, :process_scan_unavailable} ->
            {:halt, put_in(current, [:skipped, kind], :process_scan_unavailable)}

          {:error, :active_build} ->
            {:halt, put_in(current, [:skipped, kind], :active_build)}

          {:error, reason} ->
            failure = %{kind: kind, path: path, reason: reason}
            {:cont, Map.update!(current, :failures, &[failure | &1])}
        end
      end)
    end
  end

  defp cleanup_candidate(:bazel, path, context, _cutoff, process_scanner) do
    revalidate = fn -> bazel_ready(path, context, process_scanner) end

    with true <- BazelCache.valid_candidate?(path, context.home),
         {:stale, bytes} <- tree_status(path, nil),
         :ok <- revalidate.(),
         {:ok, _entries} <- BazelCache.remove(path, revalidate) do
      {:removed, bytes}
    else
      false -> :kept
      :kept -> :kept
      {:skip, _reason} = skip -> skip
      {:error, _path, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_candidate(:rust, path, context, cutoff, process_scanner) do
    with true <- valid_candidate?(:rust, path, context),
         {:ok, stat} <- context.stat_reader.(path),
         identity = artifact_identity(stat),
         {:stale, bytes} <- tree_status(path, cutoff, context.stat_reader),
         revalidate = fn -> rust_ready(path, context, identity, cutoff, process_scanner) end,
         :ok <- revalidate.(),
         {:ok, _removed_path} <- ArtifactTree.remove(path, revalidate) do
      {:removed, bytes}
    else
      false -> :kept
      :recent -> :kept
      :kept -> :kept
      {:skip, _reason} = skip -> skip
      {:error, _path, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_candidate(kind, path, validation_root, cutoff, process_scanner) do
    with true <- valid_candidate?(kind, path, validation_root),
         {:stale, bytes} <- tree_status(path, cutoff),
         {:ok, process_names} <- process_scanner.(),
         false <- blocked?(kind, process_names),
         true <- valid_candidate?(kind, path, validation_root),
         {:ok, _removed_path} <-
           ArtifactTree.remove(path, fn ->
             artifact_ready(kind, path, validation_root, cutoff, process_scanner)
           end) do
      {:removed, bytes}
    else
      false -> :kept
      :recent -> :kept
      :kept -> :kept
      {:error, :unavailable} -> {:error, :process_scan_unavailable}
      {:error, _path, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      true -> {:error, :active_build}
    end
  end

  defp rust_ready(path, context, identity, cutoff, process_scanner) do
    with {:ok, process_names} <- process_scanner.(),
         false <- blocked?(:rust, process_names),
         {:ok, activity} <- context.activity_scanner.(),
         :idle <- ArtifactProcesses.activity(path, activity),
         true <- valid_candidate?(:rust, path, context),
         {:ok, stat} <- context.stat_reader.(path),
         ^identity <- artifact_identity(stat),
         {:stale, _bytes} <- tree_status(path, cutoff, context.stat_reader) do
      :ok
    else
      false -> :kept
      true -> {:error, :active_build}
      :recent -> :kept
      reason when reason in [:active_target, :unverifiable_target] -> {:skip, reason}
      {:error, _reason} -> {:error, :process_scan_unavailable}
      _identity -> :kept
    end
  end

  defp artifact_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp artifact_ready(kind, path, root, cutoff, process_scanner) do
    with {:ok, process_names} <- process_scanner.(),
         false <- blocked?(kind, process_names),
         true <- valid_candidate?(kind, path, root),
         {:stale, _bytes} <- tree_status(path, cutoff) do
      :ok
    else
      false -> :kept
      true -> {:error, :active_build}
      :recent -> :kept
      {:error, :unavailable} -> {:error, :process_scan_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bazel_ready(path, context, process_scanner) do
    with {:ok, process_names} <- process_scanner.(),
         false <- blocked?(:bazel, process_names),
         {:ok, activity} <- context.activity_scanner.(),
         :idle <- BazelCache.activity(path, activity),
         true <- BazelCache.valid_candidate?(path, context.home) do
      :ok
    else
      false -> :kept
      true -> {:error, :active_build}
      reason when reason in [:active_cache, :unverifiable_cache] -> {:skip, reason}
      {:error, _reason} -> {:error, :process_scan_unavailable}
    end
  end

  defp valid_candidate?(:xcode, path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    Path.dirname(expanded_path) == expanded_root and directory_without_symlink?(expanded_path)
  end

  defp valid_candidate?(:rust, path, context) do
    root = if Path.dirname(path) == context.tmp_root, do: context.tmp_root, else: context.home

    with {:ok, %{uid: owner}} <- context.stat_reader.(context.home),
         true <- directory_ancestry?(root, context.stat_reader),
         true <- safe_directory?(path, root, context.stat_reader),
         {:ok, %{uid: ^owner, major_device: device}} <- context.stat_reader.(path),
         true <- cargo_target?(path) do
      Enum.all?(["CACHEDIR.TAG", ".rustc_info.json"], fn marker ->
        match?(
          {:ok, %{type: :regular, uid: ^owner, major_device: ^device}},
          context.stat_reader.(Path.join(path, marker))
        )
      end)
    else
      _ -> false
    end
  end

  defp temporary_rust_candidates(context) do
    root = context.tmp_root

    if directory_ancestry?(root, context.stat_reader) do
      case File.ls(root) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&valid_candidate?(:rust, &1, context))
          |> Enum.sort()

        _ ->
          []
      end
    else
      []
    end
  end

  defp blocked?(:bazel, process_names),
    do: Enum.any?(["bazel", "bazelisk"], &MapSet.member?(process_names, &1))

  defp blocked?(:xcode, process_names),
    do: not MapSet.disjoint?(@xcode_processes, process_names)

  defp blocked?(:rust, process_names),
    do: not MapSet.disjoint?(@rust_processes, process_names)

  defp xcode_candidates(root) do
    if directory_without_symlink?(root) do
      case File.ls(root) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&directory_without_symlink?/1)
          |> Enum.sort()

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  defp default_rust_roots(home) do
    visible_roots =
      case File.ls(home) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.reject(&MapSet.member?(@excluded_home_entries, &1))
          |> Enum.map(&Path.join(home, &1))
          |> Enum.filter(&directory_without_symlink?/1)

        {:error, _reason} ->
          []
      end

    codex_roots =
      ["worktrees", "workspace-backups"]
      |> Enum.map(&Path.join([home, ".codex", &1]))
      |> Enum.filter(&safe_directory?(&1, home))

    codex_roots ++ visible_roots
  end

  defp discover_rust_targets(path, depth, device, stat_reader) when depth <= @max_depth do
    cond do
      not same_filesystem_directory?(path, device, stat_reader) ->
        []

      cargo_target?(path) ->
        [Path.expand(path)]

      depth == @max_depth or pruned?(path) or not directory_without_symlink?(path) ->
        []

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.flat_map(
              &discover_rust_targets(Path.join(path, &1), depth + 1, device, stat_reader)
            )

          {:error, _reason} ->
            []
        end
    end
  end

  defp discover_rust_targets(_path, _depth, _device, _stat_reader), do: []

  defp same_filesystem_directory?(path, device, stat_reader) do
    match?({:ok, %{type: :directory, major_device: ^device}}, stat_reader.(path))
  end

  defp cargo_target?(path) do
    tag_path = Path.join(path, "CACHEDIR.TAG")
    rustc_info_path = Path.join(path, ".rustc_info.json")

    with true <- directory_without_symlink?(path),
         true <- regular_file_without_symlink?(tag_path),
         true <- regular_file_without_symlink?(rustc_info_path),
         {:ok, %{size: size}} when size <= @marker_limit <- File.lstat(tag_path),
         {:ok, tag} <- File.open(tag_path, [:read, :binary], &IO.binread(&1, @marker_limit + 1)),
         true <- is_binary(tag) and byte_size(tag) <= @marker_limit do
      String.starts_with?(tag, @cargo_signature) and String.contains?(tag, @cargo_marker)
    else
      _ -> false
    end
  end

  defp pruned?(path), do: MapSet.member?(@pruned_entries, Path.basename(path))

  defp directory_without_symlink?(path) do
    match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  defp safe_directory?(path, root, stat_reader \\ &File.lstat/1) do
    with {:ok, %{type: :directory, major_device: device}} <- stat_reader.(root) do
      (path == root or String.starts_with?(path, root <> "/")) and
        same_filesystem_directory?(path, device, stat_reader) and
        (path == root or safe_directory?(Path.dirname(path), root, stat_reader))
    else
      _ -> false
    end
  end

  defp directory_ancestry?(path, stat_reader) do
    Path.type(path) == :absolute and Path.expand(path) == path and
      match?({:ok, %{type: :directory}}, stat_reader.(path)) and
      (path == "/" or directory_ancestry?(Path.dirname(path), stat_reader))
  end

  defp regular_file_without_symlink?(path) do
    match?({:ok, %{type: :regular}}, File.lstat(path))
  end

  defp tree_status(path, cutoff, stat_reader \\ &File.lstat/1) do
    with {:ok, %{major_device: device}} <- stat_reader.(path) do
      tree_status(path, cutoff, stat_reader, device)
    end
  end

  defp tree_status(path, cutoff, stat_reader, device) do
    with {:ok, %{major_device: ^device}} <- stat_reader.(path),
         {:ok, stat} <- File.lstat(path, time: :posix),
         false <- not is_nil(cutoff) and stat.mtime > cutoff do
      case stat.type do
        :directory -> directory_tree_status(path, stat.size, cutoff, stat_reader, device)
        _type -> {:stale, stat.size}
      end
    else
      true -> :recent
      {:ok, _other_device} -> {:error, :different_filesystem}
      {:error, reason} -> {:error, reason}
    end
  end

  defp directory_tree_status(path, own_size, cutoff, stat_reader, device) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:stale, own_size}, fn entry, {:stale, bytes} ->
          case tree_status(Path.join(path, entry), cutoff, stat_reader, device) do
            {:stale, entry_bytes} -> {:cont, {:stale, bytes + entry_bytes}}
            :recent -> {:halt, :recent}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp active_process_names do
    with {:ok, uid} <- BazelCache.command("/usr/bin/id", ["-u"]),
         {:ok, output} <-
           BazelCache.command("/bin/ps", ["-ww", "-U", String.trim(uid), "-o", "comm="]) do
      {:ok, parse_process_names(output)}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
