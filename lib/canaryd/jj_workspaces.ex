defmodule Canaryd.JjWorkspaces do
  @moduledoc false

  alias Canaryd.{BazelCache, WorkspaceRedundancy}

  @max_depth 12
  @jj_locations ["/opt/homebrew/bin/jj", "/usr/local/bin/jj"]
  @pruned_entries MapSet.new([
                    ".git",
                    ".gradle",
                    ".jj",
                    ".venv",
                    "DerivedData",
                    "Pods",
                    "_build",
                    ".context",
                    ".next",
                    "build",
                    "deps",
                    "dist",
                    "node_modules",
                    "target",
                    "vendor"
                  ])

  def parse_workspace_list(output) when is_binary(output) do
    lines = String.split(output, "\n", trim: true)

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, workspaces} ->
      case parse_workspace_line(line) do
        {:ok, workspace} -> {:cont, {:ok, [workspace | workspaces]}}
        :error -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, [_ | _] = workspaces} -> {:ok, Enum.reverse(workspaces)}
      {:ok, []} -> {:error, :malformed}
      error -> error
    end
  end

  def list_workspaces(repo) do
    case jj_executable() do
      nil ->
        {:error, :unavailable}

      executable ->
        case BazelCache.command(executable, [
               "--at-op=@",
               "--ignore-working-copy",
               "--no-pager",
               "--color=never",
               "-R",
               repo,
               "workspace",
               "list",
               "-T",
               ~S(name ++ "\t" ++ root ++ "\n")
             ]) do
          {:ok, output} -> parse_workspace_list(output)
          {:error, _reason} = error -> error
        end
    end
  end

  def candidates(roots, options \\ []) do
    home = Keyword.fetch!(options, :home)
    lister = Keyword.get(options, :workspace_lister, &list_workspaces/1)
    stat_reader = Keyword.get(options, :stat_reader, &File.lstat/1)

    roots
    |> Enum.flat_map(&discover_repos(&1, home, stat_reader))
    |> Enum.uniq()
    |> Enum.flat_map(&forgotten_children(&1, lister, home, stat_reader))
    |> Enum.sort()
  end

  def valid_candidate?(path, context) do
    repo = Path.dirname(Path.dirname(path))

    with true <- structural_candidate?(path, context),
         {:ok, workspaces} <- context.lister.(repo),
         false <- MapSet.member?(tracked_paths(workspaces), Path.expand(path)),
         true <- WorkspaceRedundancy.redundant?(path, Path.join(repo, ".git"), :jj_workspace) do
      true
    else
      _ -> false
    end
  end

  defp forgotten_children(repo, lister, home, stat_reader) do
    context = %{home: home, lister: lister, stat_reader: stat_reader}

    case lister.(repo) do
      {:ok, workspaces} ->
        tracked = tracked_paths(workspaces)
        container = Path.join(repo, "_jj_workspaces")

        case File.ls(container) do
          {:ok, entries} ->
            entries
            |> Enum.map(&Path.join(container, &1))
            |> Enum.filter(fn path ->
              structural_candidate?(path, context) and
                not MapSet.member?(tracked, Path.expand(path))
            end)

          _ ->
            []
        end

      {:error, _reason} ->
        []
    end
  end

  defp structural_candidate?(path, context) do
    repo = Path.dirname(Path.dirname(path))
    container = Path.join(repo, "_jj_workspaces")
    name = Path.basename(path)
    home = context.home
    stat_reader = context.stat_reader

    with false <- String.starts_with?(name, "."),
         false <- name == "default",
         true <- Path.dirname(path) == container,
         {:ok, %{uid: owner, major_device: device}} <- stat_reader.(home),
         true <- jj_repo?(repo, device, owner, stat_reader),
         true <- safe_directory?(path, home, owner, device, stat_reader),
         {:ok, %{type: :directory, uid: ^owner, major_device: ^device}} <- stat_reader.(path),
         true <- linked_workspace?(path, repo, owner, device, stat_reader) do
      true
    else
      _ -> false
    end
  end

  defp tracked_paths(workspaces) do
    MapSet.new(workspaces, & &1.path)
  end

  defp discover_repos(root, home, stat_reader) do
    with {:ok, %{type: :directory, major_device: device, uid: owner}} <- stat_reader.(home),
         {:ok, %{type: :directory, major_device: ^device, uid: ^owner}} <- stat_reader.(root) do
      walk_repos(root, 0, device, owner, stat_reader)
    else
      _ -> []
    end
  end

  defp walk_repos(path, depth, device, owner, stat_reader) do
    name = Path.basename(path)

    cond do
      not owned_directory?(path, device, owner, stat_reader) ->
        []

      name == "_jj_workspaces" ->
        repo = Path.dirname(path)
        if jj_repo?(repo, device, owner, stat_reader), do: [Path.expand(repo)], else: []

      depth >= @max_depth or pruned?(name) ->
        []

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              walk_repos(Path.join(path, entry), depth + 1, device, owner, stat_reader)
            end)

          _ ->
            []
        end
    end
  end

  defp jj_repo?(repo, device, owner, stat_reader) do
    Enum.all?([".jj", ".git"], fn marker ->
      match?(
        {:ok, %{type: :directory, uid: ^owner, major_device: ^device}},
        stat_reader.(Path.join(repo, marker))
      )
    end)
  end

  defp linked_workspace?(path, repo, owner, device, stat_reader) do
    marker = Path.join([path, ".jj", "repo"])

    with {:ok, %{type: :directory, uid: ^owner, major_device: ^device}} <-
           stat_reader.(Path.join(path, ".jj")),
         {:ok, %{type: :regular, uid: ^owner, major_device: ^device, size: size}} <-
           stat_reader.(marker),
         true <- size <= 512,
         {:ok, reference} <- File.read(marker) do
      Path.expand(reference, Path.join(path, ".jj")) == Path.join([repo, ".jj", "repo"])
    else
      _ -> false
    end
  end

  defp pruned?(name), do: MapSet.member?(@pruned_entries, name)

  defp owned_directory?(path, device, owner, stat_reader) do
    match?(
      {:ok, %{type: :directory, uid: ^owner, major_device: ^device}},
      stat_reader.(path)
    )
  end

  defp safe_directory?(path, root, owner, device, stat_reader) do
    (path == root or String.starts_with?(path, root <> "/")) and
      owned_directory?(path, device, owner, stat_reader) and
      (path == root or safe_directory?(Path.dirname(path), root, owner, device, stat_reader))
  end

  defp parse_workspace_line(line) do
    case String.split(line, "\t", parts: 2) do
      [name, path]
      when name != "" and path != "" and not is_nil(path) ->
        path = String.trim(path)

        if Path.type(path) == :absolute and Path.expand(path) == path,
          do: {:ok, %{name: name, path: path}},
          else: :error

      _ ->
        :error
    end
  end

  defp jj_executable do
    System.find_executable("jj") ||
      Enum.find(@jj_locations, &File.regular?/1)
  end
end
