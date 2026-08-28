defmodule Canaryd.BuildCleanup do
  @moduledoc """
  Removes stale, reproducible Xcode and Cargo build artifacts.

  Candidate discovery and process checks are intentionally conservative. A
  path is removed only after its type, markers, complete tree age, and active
  build state have all been revalidated.
  """

  alias Canaryd.{Duration, Paths}

  @retention Duration.days(7)
  @cargo_signature "Signature: 8a477f597d28d172789f06886806bc55"
  @cargo_marker "cache directory tag created by cargo"
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
  def retention, do: @retention

  @doc "Run one exclusive build cleanup round."
  def run(options \\ []) do
    home = Keyword.get(options, :home, Paths.home_dir())

    lock_path =
      Keyword.get(options, :lock_path, Path.join(Paths.support_dir(), "build-cleanup.lock"))

    File.mkdir_p!(Path.dirname(lock_path))

    case File.open(lock_path, [:write, :exclusive]) do
      {:error, :eexist} ->
        {:error, :locked}

      {:ok, lock} ->
        try do
          {:ok, cleanup(home, options)}
        after
          File.close(lock)
          File.rm(lock_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def rust_candidates(roots) do
    roots
    |> Enum.flat_map(&discover_rust_targets(&1, 0))
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

  defp cleanup(home, options) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    process_scanner = Keyword.get(options, :process_scanner, &active_process_names/0)
    rust_roots = Keyword.get_lazy(options, :rust_roots, fn -> default_rust_roots(home) end)
    xcode_root = Path.join([home, "Library", "Developer", "Xcode", "DerivedData"])

    result = %{
      removed: [],
      reclaimed_bytes: 0,
      skipped: %{xcode: nil, rust: nil},
      failures: []
    }

    case process_scanner.() do
      {:ok, process_names} ->
        cutoff =
          now
          |> Duration.add(-@retention)
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
          rust_candidates(rust_roots),
          nil,
          cutoff,
          process_names,
          process_scanner
        )
        |> Map.update!(:removed, &Enum.reverse/1)
        |> Map.update!(:failures, &Enum.reverse/1)

      {:error, _reason} ->
        put_in(result.skipped, %{
          xcode: :process_scan_unavailable,
          rust: :process_scan_unavailable
        })
    end
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

  defp cleanup_candidate(kind, path, validation_root, cutoff, process_scanner) do
    with true <- valid_candidate?(kind, path, validation_root),
         {:stale, bytes} <- tree_status(path, cutoff),
         {:ok, process_names} <- process_scanner.(),
         false <- blocked?(kind, process_names),
         {:ok, _removed_entries} <- File.rm_rf(path) do
      {:removed, bytes}
    else
      false -> :kept
      :recent -> :kept
      {:error, :unavailable} -> {:error, :process_scan_unavailable}
      {:error, _path, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      true -> {:error, :active_build}
    end
  end

  defp valid_candidate?(:xcode, path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    Path.dirname(expanded_path) == expanded_root and directory_without_symlink?(expanded_path)
  end

  defp valid_candidate?(:rust, path, _root), do: cargo_target?(path)

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

    codex_worktrees = Path.join([home, ".codex", "worktrees"])

    if directory_without_symlink?(codex_worktrees) do
      [codex_worktrees | visible_roots]
    else
      visible_roots
    end
  end

  defp discover_rust_targets(path, depth) when depth <= @max_depth do
    cond do
      cargo_target?(path) ->
        [Path.expand(path)]

      depth == @max_depth or pruned?(path) or not directory_without_symlink?(path) ->
        []

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.flat_map(&discover_rust_targets(Path.join(path, &1), depth + 1))

          {:error, _reason} ->
            []
        end
    end
  end

  defp discover_rust_targets(_path, _depth), do: []

  defp cargo_target?(path) do
    tag_path = Path.join(path, "CACHEDIR.TAG")
    rustc_info_path = Path.join(path, ".rustc_info.json")

    with true <- directory_without_symlink?(path),
         true <- regular_file_without_symlink?(tag_path),
         true <- regular_file_without_symlink?(rustc_info_path),
         {:ok, tag} <- File.read(tag_path) do
      String.contains?(tag, @cargo_signature) and String.contains?(tag, @cargo_marker)
    else
      _ -> false
    end
  end

  defp pruned?(path), do: MapSet.member?(@pruned_entries, Path.basename(path))

  defp directory_without_symlink?(path) do
    match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  defp regular_file_without_symlink?(path) do
    match?({:ok, %{type: :regular}}, File.lstat(path))
  end

  defp tree_status(path, cutoff) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         false <- stat.mtime > cutoff do
      case stat.type do
        :directory -> directory_tree_status(path, stat.size, cutoff)
        _type -> {:stale, stat.size}
      end
    else
      true -> :recent
      {:error, reason} -> {:error, reason}
    end
  end

  defp directory_tree_status(path, own_size, cutoff) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:stale, own_size}, fn entry, {:stale, bytes} ->
          case tree_status(Path.join(path, entry), cutoff) do
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
    with {uid, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
         {output, 0} <-
           System.cmd("ps", ["-U", String.trim(uid), "-o", "comm="], stderr_to_stdout: true) do
      {:ok, parse_process_names(output)}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
