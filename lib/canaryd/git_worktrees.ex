defmodule Canaryd.GitWorktrees do
  @moduledoc false

  alias Canaryd.WorkspaceRedundancy

  @max_depth 12
  @marker_limit 4_096
  @pruned_entries MapSet.new(
                    ~w(.git .jj .gradle .venv DerivedData Pods _build .next build deps dist node_modules target vendor)
                  )

  @doc "Find physical Git worktrees whose Git registration has already disappeared."
  def candidates(roots, options) do
    home = Keyword.fetch!(options, :home)
    stat_reader = Keyword.get(options, :stat_reader, &File.lstat/1)

    with {:ok, %{type: :directory, uid: owner, major_device: device}} <- stat_reader.(home) do
      roots
      |> Enum.flat_map(&walk(&1, 0, home, owner, device, stat_reader))
      |> Enum.uniq()
      |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc false
  def valid_candidate?(path, context) do
    home = context.home
    stat_reader = context.stat_reader

    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         true <- String.starts_with?(path, home <> "/"),
         {:ok, %{type: :directory, uid: owner, major_device: device}} <- stat_reader.(home),
         true <- safe_directory?(path, home, owner, device, stat_reader),
         {:ok, git_dir} <- orphan_git_dir(path, home, owner, device, stat_reader),
         true <- WorkspaceRedundancy.redundant?(path, git_dir, :git_worktree) do
      true
    else
      _ -> false
    end
  end

  defp walk(path, depth, home, owner, device, stat_reader) do
    name = Path.basename(path)

    cond do
      depth > @max_depth or MapSet.member?(@pruned_entries, name) ->
        []

      not safe_directory?(path, home, owner, device, stat_reader) ->
        []

      match?({:ok, %{type: :regular}}, stat_reader.(Path.join(path, ".git"))) ->
        case orphan_git_dir(path, home, owner, device, stat_reader) do
          {:ok, _git_dir} -> [Path.expand(path)]
          _ -> []
        end

      depth == @max_depth ->
        []

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              walk(Path.join(path, entry), depth + 1, home, owner, device, stat_reader)
            end)

          _ ->
            []
        end
    end
  end

  defp orphan_git_dir(path, home, owner, device, stat_reader) do
    marker = Path.join(path, ".git")

    with {:ok, %{type: :regular, uid: ^owner, major_device: ^device, size: size}} <-
           stat_reader.(marker),
         true <- size <= @marker_limit,
         {:ok, text} <- File.read(marker),
         [_, reference] <- Regex.run(~r/\Agitdir: ([^\r\n]+)\n?\z/, text),
         metadata = Path.expand(reference, path),
         true <- Path.type(metadata) == :absolute,
         true <- Path.basename(Path.dirname(metadata)) == "worktrees",
         git_dir = Path.dirname(Path.dirname(metadata)),
         true <- Path.basename(git_dir) == ".git",
         true <- String.starts_with?(git_dir, home <> "/"),
         true <- safe_directory?(git_dir, home, owner, device, stat_reader),
         {:error, :enoent} <- stat_reader.(metadata) do
      {:ok, git_dir}
    else
      _ -> {:error, :not_orphaned}
    end
  end

  defp safe_directory?(path, home, owner, device, stat_reader) do
    (path == home or String.starts_with?(path, home <> "/")) and
      match?(
        {:ok, %{type: :directory, uid: ^owner, major_device: ^device}},
        stat_reader.(path)
      ) and
      (path == home or safe_directory?(Path.dirname(path), home, owner, device, stat_reader))
  end
end
