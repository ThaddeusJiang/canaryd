defmodule Canaryd.WorkspaceRedundancy do
  @moduledoc false

  alias Canaryd.BazelCache

  @max_entries 20_000
  @cache_names MapSet.new(~w(target node_modules .next _build deps dist build DerivedData))

  @doc "Require an exact match to the repository HEAD apart from known build caches."
  def redundant?(path, git_dir, kind, runner \\ &BazelCache.command/2) do
    git = System.find_executable("git") || "/usr/bin/git"
    base = ["--no-optional-locks", "--git-dir=#{git_dir}", "--work-tree=#{path}"]

    with {:ok, _} <- runner.(git, base ++ ["diff", "--quiet", "HEAD", "--"]),
         {:ok, _} <- runner.(git, base ++ ["diff", "--cached", "--quiet", "HEAD", "--"]),
         {:ok, untracked} <-
           runner.(
             git,
             base ++ ["ls-files", "--others", "--directory", "--exclude-standard", "-z"]
           ),
         {:ok, ignored} <-
           runner.(
             git,
             base ++
               ["ls-files", "--others", "--ignored", "--directory", "--exclude-standard", "-z"]
           ),
         true <- safe_extras?(untracked, kind) and safe_extras?(ignored, kind),
         true <- no_nested_repository?(path, kind) do
      true
    else
      _ -> false
    end
  end

  defp safe_extras?(output, kind) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.all?(fn relative ->
      parts = Path.split(relative)

      case parts do
        [".jj" | _] when kind == :jj_workspace -> true
        [".git"] when kind == :git_worktree -> true
        _ -> Enum.any?(parts, &MapSet.member?(@cache_names, &1))
      end
    end)
  end

  defp no_nested_repository?(path, kind) do
    case inspect_tree(path, path, kind, @max_entries) do
      {:ok, _remaining} -> true
      _ -> false
    end
  end

  defp inspect_tree(_path, _root, _kind, 0), do: {:error, :too_many_entries}

  defp inspect_tree(path, root, kind, remaining) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, entries} <- File.ls(path) do
      Enum.reduce_while(entries, {:ok, remaining - 1}, fn entry, {:ok, left} ->
        child = Path.join(path, entry)

        cond do
          entry == ".jj" and path == root and kind == :jj_workspace ->
            {:cont, {:ok, left}}

          entry == ".git" and path == root and kind == :git_worktree ->
            {:cont, {:ok, left}}

          entry in [".git", ".jj"] ->
            {:halt, {:error, :nested_repository}}

          true ->
            case File.lstat(child) do
              {:ok, %{type: :directory}} ->
                case inspect_tree(child, root, kind, left) do
                  {:ok, rest} -> {:cont, {:ok, rest}}
                  error -> {:halt, error}
                end

              {:ok, %{type: :regular}} when left > 0 ->
                {:cont, {:ok, left - 1}}

              _ ->
                {:halt, {:error, :unverifiable_tree}}
            end
        end
      end)
    end
  end
end
