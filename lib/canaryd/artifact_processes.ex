defmodule Canaryd.ArtifactProcesses do
  @moduledoc false

  alias Canaryd.BazelCache

  # ps preserves executable paths, including spaces. Only processes whose
  # launch path cannot be resolved need a PID-scoped, text-only lsof query.
  # Never enumerate every open file on the machine to decide whether to clean.
  def scan(runner \\ &BazelCache.command/2) do
    with {:ok, uid} <- runner.("/usr/bin/id", ["-u"]),
         {owner, ""} when owner >= 0 <- Integer.parse(String.trim(uid)),
         {:ok, output} <-
           runner.("/bin/ps", ["-ww", "-U", to_string(owner), "-o", "pid=,stat=,comm="]),
         {:ok, processes} <- parse_processes(output),
         {:ok, snapshot} <- resolve_processes(processes, runner) do
      {:ok, snapshot}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def activity(path, %{paths: paths, names: %MapSet{} = names}) when is_list(paths) do
    target = canonical_or_expanded(path)

    cond do
      Enum.any?(paths, &within?(&1, target)) -> :active_target
      MapSet.size(names) == 0 -> :idle
      true -> matching_executable(path, names)
    end
  rescue
    _ -> :unverifiable_target
  end

  def activity(_path, _snapshot), do: :unverifiable_target

  defp parse_processes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, processes} ->
      case String.split(String.trim(row), ~r/\s+/, parts: 3) do
        [pid_text, status, command] ->
          case Integer.parse(pid_text) do
            {pid, ""} when pid > 0 and command != "" ->
              if String.starts_with?(status, "Z"),
                do: {:cont, {:ok, processes}},
                else: {:cont, {:ok, [%{pid: pid, command: command} | processes]}}

            _ ->
              {:halt, {:error, :unavailable}}
          end

        _ ->
          {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :unavailable}
      result -> result
    end
  end

  defp resolve_processes(processes, runner) do
    {paths, unresolved} =
      Enum.reduce(processes, {[], []}, fn process, {paths, unresolved} ->
        case canonical(process.command) do
          {:ok, path} -> {[path | paths], unresolved}
          _ -> {paths, [process | unresolved]}
        end
      end)

    case unresolved do
      [] ->
        {:ok, %{paths: Enum.uniq(paths), names: MapSet.new()}}

      _ ->
        pids = unresolved |> Enum.map(& &1.pid) |> Enum.sort()
        args = ["-nP", "-a", "-p", Enum.join(pids, ","), "-d", "txt", "-Fpn"]

        with {:ok, output} <- runner.("/usr/sbin/lsof", args),
             {:ok, text_paths} <- parse_text_paths(output, MapSet.new(pids)) do
          names = MapSet.new(unresolved, &Path.basename(&1.command))

          launches =
            for %{command: command} <- unresolved, Path.type(command) == :absolute, do: command

          normalized =
            (paths ++ text_paths ++ launches) |> Enum.map(&canonical_or_expanded/1) |> Enum.uniq()

          {:ok, %{paths: normalized, names: names}}
        end
    end
  end

  defp parse_text_paths(output, expected) do
    result =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({nil, MapSet.new(), []}, fn
        "p" <> pid_text, {_pid, seen, paths} ->
          case Integer.parse(pid_text) do
            {pid, ""} when pid > 0 ->
              if MapSet.member?(expected, pid),
                do: {:cont, {pid, seen, paths}},
                else: {:halt, :invalid}

            _ ->
              {:halt, :invalid}
          end

        "n/" <> path, {pid, seen, paths} when is_integer(pid) ->
          {:cont, {pid, MapSet.put(seen, pid), ["/" <> path | paths]}}

        field, {pid, _seen, _paths} = state when field in ["ftxt", "fmem"] and is_integer(pid) ->
          {:cont, state}

        _, _ ->
          {:halt, :invalid}
      end)

    case result do
      {_pid, ^expected, paths} -> {:ok, paths}
      _ -> {:error, :unavailable}
    end
  end

  defp canonical_or_expanded(path) do
    case canonical(path) do
      {:ok, resolved} -> resolved
      _ -> Path.expand(path)
    end
  end

  defp canonical(path) do
    if Path.type(path) == :absolute do
      resolve_components(Path.split(Path.expand(path)), "/", 40)
    else
      {:error, :relative}
    end
  end

  defp resolve_components([], path, _remaining), do: {:ok, path}

  defp resolve_components(["/" | rest], path, remaining),
    do: resolve_components(rest, path, remaining)

  defp resolve_components(_parts, _path, 0), do: {:error, :eloop}

  defp resolve_components([part | rest], parent, remaining) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        with {:ok, link} <- File.read_link(path) do
          destination = Path.expand(link, parent)
          resolve_components(Path.split(destination) ++ rest, "/", remaining - 1)
        end

      {:ok, _stat} ->
        resolve_components(rest, path, remaining)

      error ->
        error
    end
  end

  defp within?(path, target), do: path == target or String.starts_with?(path, target <> "/")

  defp matching_executable(path, names) do
    with {:ok, %{type: :directory, major_device: device}} <- File.lstat(path) do
      matching_executable(path, names, device)
    else
      _ -> :unverifiable_target
    end
  end

  defp matching_executable(path, names, device) do
    case File.lstat(path) do
      {:ok, %{major_device: other}} when other != device ->
        :unverifiable_target

      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 and MapSet.member?(names, Path.basename(path)),
          do: :active_target,
          else: :idle

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.reduce_while(entries, :idle, fn entry, :idle ->
              case matching_executable(Path.join(path, entry), names, device) do
                :idle -> {:cont, :idle}
                other -> {:halt, other}
              end
            end)

          _ ->
            :unverifiable_target
        end

      {:ok, _stat} ->
        :idle

      _ ->
        :unverifiable_target
    end
  end
end
