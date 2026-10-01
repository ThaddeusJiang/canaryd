defmodule Canaryd.WorkspaceActivity do
  @moduledoc false

  alias Canaryd.BazelCache

  @doc "Inspect current-user process working directories before removing a workspace."
  def scan(runner \\ &BazelCache.command/2) do
    with {:ok, uid} <- runner.("/usr/bin/id", ["-u"]),
         {owner, ""} when owner >= 0 <- Integer.parse(String.trim(uid)),
         {:ok, output} <-
           runner.("/usr/sbin/lsof", [
             "-nP",
             "-a",
             "-d",
             "cwd",
             "-u",
             to_string(owner),
             "-Fpn"
           ]) do
      parse(output)
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, nil, false, MapSet.new(), %{}}, fn
      "p" <> text, {:ok, _pid, _cwd, seen, paths} ->
        case Integer.parse(text) do
          {pid, ""} when pid > 1 ->
            {:cont, {:ok, pid, false, MapSet.put(seen, pid), paths}}

          _ ->
            {:halt, {:error, :unavailable}}
        end

      "fcwd", {:ok, pid, false, seen, paths} when is_integer(pid) ->
        {:cont, {:ok, pid, true, seen, paths}}

      "n/" <> path, {:ok, pid, true, seen, paths} when is_integer(pid) and path != "" ->
        {:cont, {:ok, pid, false, seen, Map.put(paths, pid, "/" <> path)}}

      _, _ ->
        {:halt, {:error, :unavailable}}
    end)
    |> case do
      {:ok, _pid, _cwd, seen, paths} ->
        if MapSet.size(seen) > 0 and MapSet.new(Map.keys(paths)) == seen,
          do: {:ok, paths |> Map.values() |> Enum.uniq()},
          else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc false
  def activity(workspace, cwds) when is_list(cwds) do
    root = Path.expand(workspace)

    if Enum.any?(cwds, fn cwd ->
         cwd = Path.expand(cwd)
         cwd == root or String.starts_with?(cwd, root <> "/")
       end),
       do: :active_target,
       else: :idle
  end

  def activity(_workspace, _cwds), do: :unverifiable_target
end
