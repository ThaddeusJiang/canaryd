defmodule Canaryd.Apps.UnresponsiveTest do
  use ExUnit.Case, async: true

  alias Canaryd.Apps.Unresponsive

  test "parses an unresponsive app scan" do
    output =
      "42\tWriter%20Pro\tcom.example.writer\t%2FApplications%2FWriter%20Pro.app\n"

    assert Unresponsive.parse_scan(output) ==
             {:ok,
              [
                %{
                  id: "com.example.writer",
                  name: "Writer Pro",
                  pid: 42,
                  bundle_id: "com.example.writer",
                  bundle_path: "/Applications/Writer Pro.app"
                }
              ]}
  end

  test "uses the bundle path when the bundle identifier is absent" do
    output = "42\tWriter\t\t%2FApplications%2FWriter.app\n"

    assert {:ok, [%{id: "/Applications/Writer.app"}]} = Unresponsive.parse_scan(output)
  end

  test "rejects malformed scan rows" do
    assert Unresponsive.parse_scan("not-a-valid-row\n") ==
             {:error, {:invalid_scan_row, "not-a-valid-row"}}
  end

  test "excludes Apple and system apps" do
    refute Unresponsive.eligible?(%{
             bundle_id: "com.apple.TextEdit",
             bundle_path: "/System/Applications/TextEdit.app"
           })

    refute Unresponsive.eligible?(%{
             bundle_id: "com.example.tool",
             bundle_path: "/System/Applications/Tool.app"
           })
  end

  test "keeps third-party apps" do
    assert Unresponsive.eligible?(%{
             bundle_id: "com.example.writer",
             bundle_path: "/Applications/Writer.app"
           })
  end
end
