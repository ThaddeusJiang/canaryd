defmodule Canaryd.WorkspaceActivityTest do
  use ExUnit.Case, async: true

  alias Canaryd.WorkspaceActivity

  test "detects a process cwd inside a worktree" do
    assert {:ok, cwds} =
             WorkspaceActivity.parse("p123\nfcwd\nn/Users/test/worktree/src\np456\nfcwd\nn/tmp\n")

    assert WorkspaceActivity.activity("/Users/test/worktree", cwds) == :active_target
    assert WorkspaceActivity.activity("/Users/test/worktree-other", cwds) == :idle
  end

  test "missing or malformed cwd data is unavailable" do
    assert WorkspaceActivity.parse("p123\nfcwd\nn/tmp\np456\n") ==
             {:error, :unavailable}

    assert WorkspaceActivity.parse("p123\nn/tmp\n") == {:error, :unavailable}
    assert WorkspaceActivity.parse("") == {:error, :unavailable}
  end
end
