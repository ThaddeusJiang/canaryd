defmodule Canaryd.WorkspaceRedundancyTest do
  use ExUnit.Case, async: true

  alias Canaryd.WorkspaceRedundancy

  setup do
    root = Path.join("/private/tmp", "canaryd-redundancy-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    checkout = Path.join(root, "checkout")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q"])
    git(repo, ["config", "user.name", "Canaryd Test"])
    git(repo, ["config", "user.email", "canaryd@example.invalid"])
    File.write!(Path.join(repo, "README"), "committed content\n")
    git(repo, ["add", "README"])
    git(repo, ["commit", "-qm", "fixture"])
    File.mkdir_p!(checkout)
    File.cp!(Path.join(repo, "README"), Path.join(checkout, "README"))
    File.write!(Path.join(checkout, ".git"), "orphan marker\n")
    on_exit(fn -> File.rm_rf(root) end)
    %{repo: repo, checkout: checkout}
  end

  test "exact redundant checkout may contain known caches", %{repo: repo, checkout: checkout} do
    git_dir = Path.join(repo, ".git")
    assert WorkspaceRedundancy.redundant?(checkout, git_dir, :git_worktree)
    File.mkdir_p!(Path.join(checkout, "target"))
    File.write!(Path.join(checkout, "target/artifact"), "generated")
    assert WorkspaceRedundancy.redundant?(checkout, git_dir, :git_worktree)
  end

  test "untracked files, changed source and nested repositories prevent deletion", %{
    repo: repo,
    checkout: checkout
  } do
    git_dir = Path.join(repo, ".git")
    note = Path.join(checkout, "notes.txt")
    File.write!(note, "unique")
    refute WorkspaceRedundancy.redundant?(checkout, git_dir, :git_worktree)
    File.rm!(note)
    File.write!(Path.join(checkout, "README"), "modified")
    refute WorkspaceRedundancy.redundant?(checkout, git_dir, :git_worktree)
    File.write!(Path.join(checkout, "README"), "committed content\n")
    File.mkdir_p!(Path.join(checkout, "target/.git"))
    refute WorkspaceRedundancy.redundant?(checkout, git_dir, :git_worktree)
  end

  test "unknown ignored files prevent deletion", %{repo: repo, checkout: checkout} do
    File.write!(Path.join(repo, ".gitignore"), ".env\n")
    git(repo, ["add", ".gitignore"])
    git(repo, ["commit", "-qm", "ignore secrets"])
    File.cp!(Path.join(repo, ".gitignore"), Path.join(checkout, ".gitignore"))
    File.write!(Path.join(checkout, ".env"), "private")
    refute WorkspaceRedundancy.redundant?(checkout, Path.join(repo, ".git"), :git_worktree)
  end

  defp git(repo, args) do
    assert {_, 0} = System.cmd(System.find_executable("git"), ["-C", repo] ++ args)
  end
end
