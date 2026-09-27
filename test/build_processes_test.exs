defmodule Canaryd.BuildProcessesTest do
  use ExUnit.Case, async: true

  alias Canaryd.BuildProcesses

  test "parses detached current-user compiler processes without command lines" do
    output =
      "123 1 501 2.5 4096 /usr/bin/clang++ -cc1\n124 55 501 0.1 2048 cargo check\n125 1 0 80.0 4096 /usr/bin/clang\n126 1 501 1.0 2048 /usr/bin/node\n"

    assert [
             %{name: "clang++", pid: 123, detached: true},
             %{name: "cargo", pid: 124, detached: false}
           ] =
             BuildProcesses.parse(output, 501)

    refute inspect(BuildProcesses.parse(output, 501)) =~ "cc1"
  end

  test "skips an empty command field instead of raising" do
    assert BuildProcesses.parse("123 1 501 1.0 1024 \n", 501) == []
  end
end
