defmodule Canaryd.BuildActivityTest do
  use ExUnit.Case, async: true

  alias Canaryd.BuildActivity

  test "maps compiler working directories to their own target" do
    assert {:ok, %{cwds: ["/Users/test/git/active"]}} =
             BuildActivity.scan(
               fn ->
                 {:ok,
                  [
                    %{pid: 123, ppid: 1, name: "cargo"},
                    %{pid: 456, ppid: 1, name: "sleep"}
                  ]}
               end,
               fn "/usr/sbin/lsof", args ->
                 assert args == ["-nP", "-a", "-p", "123", "-d", "cwd", "-Fpn"]
                 {:ok, "p123\nfcwd\nn/Users/test/git/active\n"}
               end
             )

    snapshot = %{cwds: ["/Users/test/git/active"]}
    assert BuildActivity.activity("/Users/test/git/active/target", snapshot) == :active_target
    assert BuildActivity.activity("/Users/test/git/idle/target", snapshot) == :idle
  end

  test "fails closed when a compiler cwd is missing or output is malformed" do
    assert BuildActivity.parse_cwds("p123\nfcwd\nn/Users/test/git/active\n", [123, 456]) ==
             {:error, :unavailable}

    assert BuildActivity.parse_cwds("p123\nn/Users/test/git/active\np999\nn/tmp\n", [123]) ==
             {:error, :unavailable}

    assert BuildActivity.parse_cwds("p123\nn/Users/test/git/active\n", [123]) ==
             {:error, :unavailable}
  end
end
