defmodule Canaryd.StaleWorkspacesTest do
  use ExUnit.Case, async: true

  alias Canaryd.{BuildCleanup, GitWorktrees, JjWorkspaces}

  setup do
    root = Path.join("/private/tmp", "canaryd-workspaces-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q"])
    git(repo, ["config", "user.name", "Canaryd Test"])
    git(repo, ["config", "user.email", "canaryd@example.invalid"])
    File.write!(Path.join(repo, "README"), "committed content\n")
    git(repo, ["add", "README"])
    git(repo, ["commit", "-qm", "fixture"])
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, repo: repo}
  end

  test "reclaims only an unregistered redundant Git worktree", %{root: root, repo: repo} do
    orphan = Path.join(root, "orphan")
    File.mkdir_p!(orphan)
    File.cp!(Path.join(repo, "README"), Path.join(orphan, "README"))
    File.write!(Path.join(orphan, ".git"), "gitdir: #{repo}/.git/worktrees/orphan\n")
    File.mkdir_p!(Path.join(orphan, "target"))
    File.write!(Path.join(orphan, "target/artifact"), "rebuildable")

    assert GitWorktrees.candidates([root], home: root) == [orphan]
    assert GitWorktrees.valid_candidate?(orphan, %{home: root, stat_reader: &File.lstat/1})

    result = cleanup(root, workspace_roots: [root])
    assert Enum.any?(result.removed, &(&1.kind == :git_worktree and &1.path == orphan))
    refute File.exists?(orphan)
    assert File.read!(Path.join(repo, "README")) == "committed content\n"
  end

  test "keeps an orphaned Git worktree with unique files or live cwd", %{root: root, repo: repo} do
    orphan = Path.join(root, "orphan")
    File.mkdir_p!(orphan)
    File.cp!(Path.join(repo, "README"), Path.join(orphan, "README"))
    File.write!(Path.join(orphan, ".git"), "gitdir: #{repo}/.git/worktrees/orphan\n")
    File.write!(Path.join(orphan, "unique.txt"), "save me")
    assert cleanup(root, workspace_roots: [root]).removed == []
    assert File.exists?(orphan)

    File.rm!(Path.join(orphan, "unique.txt"))

    result =
      cleanup(root, workspace_roots: [root], workspace_cwd_scanner: fn -> {:ok, [orphan]} end)

    assert result.removed == []
    assert result.skipped.git_worktree == :active_target
    assert File.exists?(orphan)

    File.mkdir_p!(Path.join(repo, ".git/worktrees/orphan"))
    assert GitWorktrees.candidates([root], home: root) == []
    assert cleanup(root, workspace_roots: [root]).removed == []
  end

  test "reclaims forgotten redundant JJ workspace but retains an independent nested repo", %{
    root: root,
    repo: repo
  } do
    File.mkdir_p!(Path.join(repo, ".jj/repo"))
    forgotten = Path.join(repo, "_jj_workspaces/forgotten")
    File.mkdir_p!(Path.join(forgotten, ".jj"))
    File.cp!(Path.join(repo, "README"), Path.join(forgotten, "README"))
    File.write!(Path.join(forgotten, ".jj/repo"), "../../../.jj/repo")
    lister = fn ^repo -> {:ok, [%{name: "default", path: repo}]} end

    assert JjWorkspaces.candidates([root], home: root, workspace_lister: lister) == [forgotten]

    tracked_lister = fn ^repo ->
      {:ok,
       [
         %{name: "default", path: repo},
         %{name: "forgotten", path: forgotten}
       ]}
    end

    assert JjWorkspaces.candidates([root], home: root, workspace_lister: tracked_lister) == []

    assert JjWorkspaces.valid_candidate?(forgotten, %{
             home: root,
             lister: lister,
             stat_reader: &File.lstat/1
           })

    independent = Path.join(repo, "_jj_workspaces/independent")
    File.mkdir_p!(Path.join(independent, ".jj/repo"))
    File.mkdir_p!(Path.join(independent, ".git"))
    File.cp!(Path.join(repo, "README"), Path.join(independent, "README"))
    assert JjWorkspaces.candidates([root], home: root, workspace_lister: lister) == [forgotten]

    result = cleanup(root, workspace_roots: [root], jj_workspace_lister: lister)
    assert Enum.any?(result.removed, &(&1.kind == :jj_workspace and &1.path == forgotten))
    refute File.exists?(forgotten)
    assert File.dir?(independent)
  end

  defp cleanup(root, overrides) do
    now = ~U[2030-01-01 00:00:00Z]

    options =
      [
        home: root,
        now: now,
        lock_path: Path.join(root, "cleanup.lock"),
        rust_roots: [],
        rust_tmp_root: Path.join(root, "no-temp"),
        process_scanner: fn -> {:ok, MapSet.new()} end,
        rust_activity_scanner: fn -> {:ok, %{paths: [], names: MapSet.new()}} end,
        workspace_cwd_scanner: fn -> {:ok, []} end
      ]
      |> Keyword.merge(overrides)

    assert {:ok, result} = BuildCleanup.run(options)
    result
  end

  defp git(repo, args) do
    assert {_, 0} = System.cmd(System.find_executable("git"), ["-C", repo] ++ args)
  end
end
