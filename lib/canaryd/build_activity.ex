defmodule Canaryd.BuildActivity do
  @moduledoc false

  alias Canaryd.{BazelCache, BuildProcessStop}

  @doc "Read current-user build process working directories without stopping them."
  def scan(process_scanner \\ &BuildProcessStop.scan/0, runner \\ &BazelCache.command/2) do
    with {:ok, processes} <- process_scanner.() do
      builds = BuildProcessStop.candidates(processes)

      case builds do
        [] ->
          {:ok, %{cwds: []}}

        _ ->
          pids = builds |> Enum.map(& &1.pid) |> Enum.sort()

          with {:ok, output} <-
                 runner.("/usr/sbin/lsof", [
                   "-nP",
                   "-a",
                   "-p",
                   Enum.join(pids, ","),
                   "-d",
                   "cwd",
                   "-Fpn"
                 ]),
               {:ok, cwds} <- parse_cwds(output, pids) do
            {:ok, %{cwds: cwds}}
          else
            _ -> {:error, :unavailable}
          end
      end
    end
  end

  @doc false
  def parse_cwds(output, pids) do
    expected = MapSet.new(pids)

    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, nil, false, %{}}, fn
      "p" <> text, {:ok, _pid, _cwd, paths} ->
        case Integer.parse(text) do
          {pid, ""} when pid > 1 ->
            if MapSet.member?(expected, pid),
              do: {:cont, {:ok, pid, false, paths}},
              else: {:halt, {:error, :unavailable}}

          _ ->
            {:halt, {:error, :unavailable}}
        end

      "n/" <> path, {:ok, pid, true, paths} when is_integer(pid) and path != "" ->
        {:cont, {:ok, pid, false, Map.put(paths, pid, "/" <> path)}}

      "fcwd", {:ok, pid, false, paths} when is_integer(pid) ->
        {:cont, {:ok, pid, true, paths}}

      _, _ ->
        {:halt, {:error, :unavailable}}
    end)
    |> case do
      {:ok, _pid, _cwd, paths} ->
        if MapSet.new(Map.keys(paths)) == expected,
          do: {:ok, Map.values(paths)},
          else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc false
  def activity(target, %{cwds: cwds}) when is_list(cwds) do
    project = target |> Path.dirname() |> Path.expand()

    if Enum.any?(cwds, fn cwd ->
         cwd = Path.expand(cwd)
         within?(cwd, project) or within?(project, cwd)
       end) do
      :active_target
    else
      :idle
    end
  end

  def activity(_target, _snapshot), do: :unverifiable_target

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
