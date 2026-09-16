defmodule Canaryd.SccacheCleanup do
  @moduledoc false
  alias Canaryd.BazelCache
  @hex String.graphemes("0123456789abcdef")
  @builders ~r/^(cargo|rustc|clang(\+\+)?|gcc|g\+\+|cc1|xcodebuild|sccache-dist)(-\d+)?$/

  # sccache v0.17 records LRU reads in mtime and tolerates externally evicted
  # objects. Only complete digest objects are eligible; never touch temporary
  # writes or the separate preprocessor cache. No server restart is required.
  def run(home, cutoff, options \\ []) do
    root = Path.join(home, "Library/Caches/Mozilla.sccache")
    scanner = Keyword.get(options, :activity_scanner, &scan_activity/0)

    context = %{
      home: home,
      root: root,
      cutoff: cutoff,
      scanner: scanner,
      limit: Keyword.get(options, :max_objects, 10_000),
      deadline: System.monotonic_time(:millisecond) + Keyword.get(options, :budget, 30_000)
    }

    result = %{
      removed_objects: 0,
      reclaimed_bytes: 0,
      kept_objects: 0,
      skipped: nil,
      failures: []
    }

    cond do
      not File.exists?(root) ->
        result

      not safe_directory?(root, home) ->
        %{result | skipped: :unsafe_cache}

      true ->
        case scanner.() do
          {:ok, _open} ->
            Enum.reduce_while(Enum.shuffle(for(a <- @hex, b <- @hex, do: {a, b})), result, fn {a,
                                                                                               b},
                                                                                              acc ->
              bucket = Path.join([root, a, b])
              next = clean_bucket(bucket, a <> b, context, acc)
              if next.skipped, do: {:halt, next}, else: {:cont, next}
            end)

          {:error, reason} ->
            %{result | skipped: reason}
        end
    end
  end

  defp clean_bucket(bucket, prefix, context, result) do
    cond do
      exhausted?(context, result) ->
        %{result | skipped: :budget_exhausted}

      not safe_directory?(bucket, context.home) ->
        result

      true ->
        case bucket_entries(bucket) do
          {:ok, entries} when length(entries) <= 10_000 ->
            candidates = Enum.filter(entries, &Regex.match?(~r/\A#{prefix}[0-9a-f]{62}\z/, &1))
            clean_objects(bucket, candidates, context, result)

          {:ok, _} ->
            %{result | skipped: :bucket_too_large}

          {:error, reason} ->
            failure(result, bucket, reason)
        end
    end
  end

  # Native command output is capped at 8 MiB and five seconds by command/2;
  # reject oversized buckets before splitting the bounded output.
  defp bucket_entries(bucket) do
    case BazelCache.command("/usr/bin/find", [
           bucket,
           "-mindepth",
           "1",
           "-maxdepth",
           "1",
           "-print"
         ]) do
      {:ok, output} when byte_size(output) <= 1_048_576 ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.map(&Path.basename/1)}

      {:ok, _} ->
        {:error, :bucket_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean_objects(bucket, entries, context, result) do
    # Refresh activity for every bucket and recheck each object's identity and
    # last use immediately before unlinking. An open file remains untouched.
    case context.scanner.() do
      {:error, reason} ->
        %{result | skipped: reason}

      {:ok, open} ->
        Enum.reduce_while(entries, result, fn name, acc ->
          path = Path.join(bucket, name)

          if exhausted?(context, acc) do
            {:halt, %{acc | skipped: :budget_exhausted}}
          else
            {:cont, remove_object(path, open, context, acc)}
          end
        end)
    end
  end

  defp remove_object(path, open, context, result) do
    with false <- MapSet.member?(open, path),
         {:ok, stat} <- File.lstat(path, time: :posix),
         true <- eligible?(stat, context),
         true <- safe_directory?(Path.dirname(path), context.home),
         {:ok, ^stat} <- File.lstat(path, time: :posix) do
      case File.rm(path) do
        :ok ->
          %{
            result
            | removed_objects: result.removed_objects + 1,
              reclaimed_bytes: result.reclaimed_bytes + stat.size
          }

        {:error, :enoent} ->
          result

        {:error, reason} ->
          failure(result, path, reason)
      end
    else
      _ -> %{result | kept_objects: result.kept_objects + 1}
    end
  end

  defp eligible?(%{type: :regular} = stat, context) do
    case File.lstat(context.home) do
      {:ok, home} ->
        stat.uid == home.uid and stat.major_device == home.major_device and
          max(stat.mtime, stat.atime) <= context.cutoff

      _ ->
        false
    end
  end

  defp eligible?(_, _), do: false

  defp safe_directory?(path, home) do
    with {:ok, owner} <- File.lstat(home),
         {:ok, %{type: :directory} = stat} <- File.lstat(path),
         true <- stat.uid == owner.uid and stat.major_device == owner.major_device do
      path == home or
        (String.starts_with?(path, home <> "/") and safe_directory?(Path.dirname(path), home))
    else
      _ -> false
    end
  end

  defp exhausted?(context, result),
    do:
      result.removed_objects >= context.limit or
        System.monotonic_time(:millisecond) >= context.deadline

  defp failure(result, path, reason),
    do: %{result | failures: [%{kind: :sccache, path: path, reason: reason} | result.failures]}

  def scan_activity(runner \\ &BazelCache.command/2) do
    with {:ok, uid} <- runner.("/usr/bin/id", ["-u"]),
         {owner, ""} when owner >= 0 <- Integer.parse(String.trim(uid)),
         {:ok, output} <- runner.("/bin/ps", ["-ww", "-U", to_string(owner), "-o", "pid=,comm="]),
         {:ok, processes} <- parse_processes(output) do
      if Enum.any?(processes, fn {_pid, name} -> Regex.match?(@builders, name) end) do
        {:error, :active_build}
      else
        pids = for {pid, "sccache"} <- processes, do: pid
        open_files(pids, runner)
      end
    else
      _ -> {:error, :process_scan_unavailable}
    end
  rescue
    _ -> {:error, :process_scan_unavailable}
  end

  defp parse_processes(output) do
    Enum.reduce_while(String.split(output, "\n", trim: true), {:ok, []}, fn line, {:ok, acc} ->
      case String.split(String.trim(line), ~r/\s+/, parts: 2) do
        [pid, command] ->
          case Integer.parse(pid) do
            {number, ""} when number > 0 -> {:cont, {:ok, [{pid, Path.basename(command)} | acc]}}
            _ -> {:halt, {:error, :invalid}}
          end

        _ ->
          {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid}
      other -> other
    end
  end

  defp open_files([], _runner), do: {:ok, MapSet.new()}

  defp open_files(pids, runner) do
    case runner.("/usr/sbin/lsof", ["-nP", "-a", "-p", Enum.join(pids, ","), "-Fpn"]) do
      {:ok, output} ->
        rows = String.split(output, "\n", trim: true)
        seen = for "p" <> pid <- rows, do: pid

        if Enum.sort(seen) == Enum.sort(pids) do
          {:ok, MapSet.new(for "n/" <> path <- rows, do: "/" <> path)}
        else
          {:error, :process_scan_unavailable}
        end

      _ ->
        {:error, :process_scan_unavailable}
    end
  end
end
