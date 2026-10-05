defmodule Canaryd.JjWorkspacesTest do
  use ExUnit.Case, async: true

  alias Canaryd.JjWorkspaces

  test "parses absolute workspace roots from a stable template" do
    output = """
    default\t/Users/test/repo
    pr37-ready\t/Users/test/repo/_jj_workspaces/pr37-ready
    """

    assert {:ok, workspaces} = JjWorkspaces.parse_workspace_list(output)

    assert Enum.sort_by(workspaces, & &1.name) == [
             %{name: "default", path: "/Users/test/repo"},
             %{name: "pr37-ready", path: "/Users/test/repo/_jj_workspaces/pr37-ready"}
           ]
  end

  test "rejects an unparsable workspace list instead of guessing tracked paths" do
    assert {:error, :malformed} =
             JjWorkspaces.parse_workspace_list("default\t/Users/test/repo\nbroken\n")
  end

  test "an unresolved workspace root keeps every directory" do
    assert {:error, :malformed} =
             JjWorkspaces.parse_workspace_list("default\t/Users/test/repo\nold\t\n")
  end

  test "an empty list is unverifiable" do
    assert {:error, :malformed} = JjWorkspaces.parse_workspace_list("")
  end
end
