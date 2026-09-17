defmodule Canaryd.BazelRepositoryCache do
  @moduledoc false

  alias Canaryd.{ArtifactProcesses, ArtifactTree, BazelCache, BuildCleanup, Duration, FileLock}

  @batch_budget Duration.seconds(15)
  @round_budget Duration.seconds(60)
  @candidate_limit 16
  @batch_stops [:active_build, :active_cache, :unverifiable_cache, :process_scan_unavailable]

  @algorithms [{"sha1", 40}, {"sha256", 64}, {"sha384", 96}, {"sha512", 128}, {"blake3", 64}]
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  # Bazel 9.2.0 DownloadCache / LocalRepoContentsCache formats. Hits refresh
  # file or .recorded_inputs mtimes, not the containing cache root. Each round
  # makes bounded progress while holding every output-base lock for its batch.
  def run(home, cutoff, options \\ []) do
    clock = Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end)

    context = %{
      home: home,
      cutoff: cutoff,
      clock: clock,
      round_deadline: clock.() + @round_budget,
      candidate_limit: Keyword.get(options, :candidate_limit, @candidate_limit),
      order_candidates: Keyword.get(options, :order_candidates, &Enum.shuffle/1),
      process_scanner: Keyword.get(options, :process_scanner, &process_names/0),
      activity_scanner: Keyword.get(options, :activity_scanner, &BazelCache.scan_activity/0),
      runtime_scanner: Keyword.get(options, :runtime_scanner, &ArtifactProcesses.scan/0)
    }

    root = Path.join(home, "Library/Caches/bazel")

    with {:ok, boundary} <- directory_identity(home),
         {:ok, _ancestors} <- ancestors(root, home, boundary),
         {:ok, entries} <- File.ls(root) do
      entries
      |> Enum.filter(&String.starts_with?(&1, "_bazel_"))
      |> context.order_candidates.()
      |> Enum.reduce_while(empty_result(), fn entry, result ->
        if context.clock.() >= context.round_deadline do
          {:halt, %{result | skipped: :budget_exhausted}}
        else
          {:cont,
           cleanup_user(Path.join(root, entry), Map.put(context, :boundary, boundary), result)}
        end
      end)
      |> Map.update!(:removed, &Enum.reverse/1)
      |> Map.update!(:failures, &Enum.reverse/1)
    else
      _ -> empty_result()
    end
  end

  defp cleanup_user(user_root, context, result) do
    context = Map.put(context, :user_root, user_root)
    repo_root = Path.join(user_root, "cache/repos/v1")

    with {:ok, _} <- ancestors(repo_root, context.home, context.boundary),
         candidates when candidates != [] <- repository_candidates(repo_root, context),
         {:ok, bases} <- output_bases(context),
         :ok <- processes_idle(context, bases) do
      context =
        context
        |> Map.put(:bases, bases)
        |> Map.put(:deadline, min(context.round_deadline, context.clock.() + @batch_budget))

      case lock_bases(bases, context, fn ->
             with_contents_lock(candidates, context, fn locked_context ->
               cleanup_candidates(candidates, locked_context, result)
             end)
           end) do
        {:skip, reason} -> %{result | skipped: reason}
        updated -> updated
      end
    else
      {:skip, reason} -> %{result | skipped: reason}
      _ -> result
    end
  end

  defp repository_candidates(root, context) do
    roots =
      Enum.map(@algorithms, fn {algorithm, size} ->
        {Path.join(root, "content_addressable/" <> algorithm), {:download, size}}
      end) ++ [{Path.join(root, "contents"), :contents}]

    # Shuffle the whole pool, not individual formats: an active download
    # prefix must not repeatedly consume the contents cache's entire budget.
    roots
    |> Enum.flat_map(fn {directory, format} ->
      with {:ok, _} <- ancestors(directory, context.home, context.boundary),
           {:ok, entries} <- File.ls(directory) do
        for entry <- entries,
            hex?(entry, digest_size(format)),
            do: {Path.join(directory, entry), format}
      else
        _ -> []
      end
    end)
    |> context.order_candidates.()
  end

  defp with_contents_lock(candidates, context, callback) do
    case Enum.find(candidates, fn {_path, format} -> format == :contents end) do
      nil ->
        callback.(context)

      {path, :contents} ->
        root = Path.dirname(path)
        lock_path = Path.join(root, "gc_lock")

        with :ok <- within_budget(context),
             {:ok, _} <- ancestors(root, context.home, context.boundary) do
          case FileLock.with_lock(
                 lock_path,
                 fn ->
                   case regular_identity(lock_path, context.boundary) do
                     {:ok, identity} ->
                       callback.(Map.put(context, :gc_lock, {lock_path, identity}))

                     _ ->
                       {:skip, :unverifiable_cache}
                   end
                 end,
                 create: true
               ) do
            {:error, :locked} -> {:skip, :active_cache}
            {:error, :lock_unavailable} -> {:skip, :unverifiable_cache}
            result -> result
          end
        else
          {:skip, _} = skip -> skip
          _ -> {:skip, :unverifiable_cache}
        end
    end
  end

  defp cleanup_candidates(candidates, context, result) do
    candidates
    |> Enum.reduce_while({result, context.candidate_limit}, fn {path, format},
                                                               {current, remaining} ->
      if remaining == 0 or within_budget(context) != :ok do
        {:halt, {%{current | skipped: :budget_exhausted}, remaining}}
      else
        case eligible_hash(path, format, context) do
          {:ok, identity, bytes} ->
            if within_budget(context) == :ok do
              # Deadlines are soft: finish one eligible candidate's fresh
              # checks and removal even if it exceeds the remaining time.
              outcome =
                ArtifactTree.remove(path, fn -> ready(path, format, identity, context) end)

              updated = record(outcome, path, bytes, current)

              action =
                if match?({:skip, reason} when reason in @batch_stops, outcome),
                  do: :halt,
                  else: :cont

              {action, {updated, remaining - 1}}
            else
              {:halt, {%{current | skipped: :budget_exhausted}, remaining}}
            end

          _ ->
            {:cont, {current, remaining}}
        end
      end
    end)
    |> elem(0)
  end

  defp eligible_hash(path, format, context) do
    with {:ok, identity} <- ancestors(path, context.home, context.boundary),
         true <- valid_format?(path, format, context.boundary),
         {:stale, bytes} <- tree_status(path, context) do
      {:ok, identity, bytes}
    else
      _ -> :kept
    end
  end

  defp record({:ok, _}, path, bytes, result) do
    removed = %{kind: :bazel_repository, path: path, bytes: bytes}

    %{
      result
      | removed: [removed | result.removed],
        reclaimed_bytes: result.reclaimed_bytes + bytes
    }
  end

  defp record({:skip, reason}, _path, _bytes, result), do: %{result | skipped: reason}

  defp record({:error, reason}, path, _bytes, result) do
    failure = %{kind: :bazel_repository, path: path, reason: reason}
    %{result | failures: [failure | result.failures]}
  end

  defp record(:kept, _path, _bytes, result), do: result

  defp within_budget(context) do
    if context.clock.() < context.deadline, do: :ok, else: {:skip, :budget_exhausted}
  end

  defp ready(path, format, identity, context) do
    with :ok <- processes_idle(context, context.bases),
         {:ok, runtime} <- context.runtime_scanner.(),
         :ok <- shared_state_unchanged(context),
         :idle <- ArtifactProcesses.activity(path, runtime),
         {:ok, current} <- ancestors(path, context.home, context.boundary),
         true <- current == identity,
         true <- valid_format?(path, format, context.boundary),
         {:stale, _bytes} <- tree_status(path, context) do
      :ok
    else
      {:skip, _} = skip -> skip
      {:error, _} -> {:skip, :process_scan_unavailable}
      reason when reason in [:active_target, :unverifiable_target] -> {:skip, reason}
      _ -> :kept
    end
  end

  defp shared_state_unchanged(context) do
    with {:ok, bases} <- output_bases(context),
         true <- bases == context.bases,
         true <- gc_lock_unchanged?(context) do
      :ok
    else
      _ -> {:skip, :unverifiable_cache}
    end
  end

  defp gc_lock_unchanged?(%{gc_lock: {path, identity}, boundary: boundary}),
    do: regular_identity(path, boundary) == {:ok, identity}

  defp gc_lock_unchanged?(_context), do: true

  defp processes_idle(context, bases) do
    with {:ok, names} <- context.process_scanner.(),
         false <- Enum.any?(names, &bazel_process?/1),
         {:ok, activity} <- context.activity_scanner.() do
      Enum.reduce_while(bases, :ok, fn {path, _identity}, :ok ->
        case BazelCache.activity(path, activity) do
          :idle -> {:cont, :ok}
          reason -> {:halt, {:skip, reason}}
        end
      end)
    else
      true -> {:skip, :active_build}
      _ -> {:skip, :process_scan_unavailable}
    end
  end

  defp bazel_process?(name),
    do: name in ["bazel", "bazelisk"] or String.starts_with?(name, "bazel(")

  defp output_bases(context) do
    with {:ok, entries} <- File.ls(context.user_root) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, bases} ->
        path = Path.join(context.user_root, entry)

        if hex?(entry, 32) or
             File.lstat(Path.join(path, "DO_NOT_BUILD_HERE")) != {:error, :enoent} do
          with true <- BazelCache.valid_output_base?(path, context.home),
               {:ok, chain} <- ancestors(path, context.home, context.boundary),
               {:ok, _marker} <-
                 regular_identity(Path.join(path, "DO_NOT_BUILD_HERE"), context.boundary),
               {:ok, lock} <- regular_identity(Path.join(path, "lock"), context.boundary) do
            {:cont, {:ok, bases ++ [{path, {chain, lock}}]}}
          else
            _ -> {:halt, {:skip, :unverifiable_cache}}
          end
        else
          {:cont, {:ok, bases}}
        end
      end)
    else
      _ -> {:skip, :unverifiable_cache}
    end
  end

  defp lock_bases([], _context, callback), do: callback.()

  defp lock_bases([{path, _identity} | rest], context, callback) do
    with :ok <- within_budget(context) do
      BazelCache.with_lock(path, fn -> lock_bases(rest, context, callback) end)
    end
  end

  defp valid_format?(path, {:download, size}, boundary) do
    with {:ok, entries} <- File.ls(path),
         true <- "file" in entries do
      Enum.all?(entries, fn entry ->
        (entry == "file" or
           (String.starts_with?(entry, "id-") and
              hex?(String.replace_prefix(entry, "id-", ""), size))) and
          match?({:ok, _}, regular_identity(Path.join(path, entry), boundary))
      end)
    else
      _ -> false
    end
  end

  defp valid_format?(path, :contents, boundary) do
    with {:ok, entries} when entries != [] <- File.ls(path) do
      Enum.all?(entries, fn entry ->
        if String.ends_with?(entry, ".recorded_inputs") do
          uuid = String.replace_suffix(entry, ".recorded_inputs", "")

          Regex.match?(@uuid, uuid) and uuid in entries and
            match?({:ok, _}, regular_identity(Path.join(path, entry), boundary))
        else
          Regex.match?(@uuid, entry) and (entry <> ".recorded_inputs") in entries and
            match?({:ok, _}, owned_identity(Path.join(path, entry), :directory, boundary))
        end
      end)
    else
      _ -> false
    end
  end

  defp tree_status(path, context) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <-
           stat.uid == context.boundary.uid and stat.major_device == context.boundary.major_device,
         true <- stat.mtime <= context.cutoff do
      case stat.type do
        :directory ->
          with {:ok, entries} <- File.ls(path) do
            Enum.reduce_while(entries, {:stale, stat.size}, fn entry, {:stale, bytes} ->
              case tree_status(Path.join(path, entry), context) do
                {:stale, size} -> {:cont, {:stale, bytes + size}}
                _ -> {:halt, :kept}
              end
            end)
          else
            _ -> :kept
          end

        type when type in [:regular, :symlink] ->
          {:stale, stat.size}

        _ ->
          :kept
      end
    else
      _ -> :kept
    end
  end

  # Freeze inode, owner and filesystem for the complete path, not only the
  # selected hash. Never follow structural symlinks or enter mounted volumes.
  defp ancestors(path, home, boundary) do
    if path == home or String.starts_with?(path, home <> "/") do
      if path == home do
        with {:ok, identity} <- owned_identity(path, :directory, boundary) do
          {:ok, [{path, identity}]}
        end
      else
        with {:ok, parents} <- ancestors(Path.dirname(path), home, boundary),
             {:ok, identity} <- owned_identity(path, :directory, boundary),
             do: {:ok, [{path, identity} | parents]}
      end
    else
      {:error, :outside_home}
    end
  end

  defp directory_identity(path) do
    with {:ok, %{type: :directory} = stat} <- File.lstat(path), do: {:ok, identity(stat)}
  end

  defp regular_identity(path, boundary), do: owned_identity(path, :regular, boundary)

  defp owned_identity(path, type, boundary) do
    with {:ok, %{type: ^type, uid: owner, major_device: device} = stat} <- File.lstat(path),
         true <- owner == boundary.uid and device == boundary.major_device do
      {:ok, identity(stat)}
    else
      _ -> {:error, :unsafe_identity}
    end
  end

  defp identity(stat), do: Map.take(stat, [:inode, :uid, :major_device])
  defp hex?(text, size), do: byte_size(text) == size and String.match?(text, ~r/\A[0-9a-fA-F]+\z/)
  defp digest_size({:download, size}), do: size
  defp digest_size(:contents), do: 64
  defp empty_result, do: %{removed: [], reclaimed_bytes: 0, skipped: nil, failures: []}

  defp process_names do
    with {:ok, uid} <- BazelCache.command("/usr/bin/id", ["-u"]),
         {:ok, output} <- BazelCache.command("/bin/ps", ["-U", String.trim(uid), "-o", "comm="]) do
      {:ok, BuildCleanup.parse_process_names(output)}
    end
  end
end
