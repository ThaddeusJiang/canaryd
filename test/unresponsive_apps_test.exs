defmodule Canaryd.Apps.UnresponsiveTest do
  use ExUnit.Case, async: true

  alias Canaryd.Apps.Unresponsive

  test "parses an unresponsive app scan" do
    output =
      "42\t0\tWriter%20Pro\tcom.example.writer\t%2FApplications%2FWriter%20Pro.app\n"

    assert Unresponsive.parse_scan(output) ==
             {:ok,
              [
                %{
                  id: "com.example.writer",
                  name: "Writer Pro",
                  pid: 42,
                  activation_policy: 0,
                  bundle_id: "com.example.writer",
                  bundle_path: "/Applications/Writer Pro.app"
                }
              ]}
  end

  test "uses the bundle path when the bundle identifier is absent" do
    output = "42\t0\tWriter\t\t%2FApplications%2FWriter.app\n"

    assert {:ok, [%{id: "/Applications/Writer.app"}]} = Unresponsive.parse_scan(output)
  end

  test "rejects malformed scan rows" do
    assert Unresponsive.parse_scan("not-a-valid-row\n") ==
             {:error, {:invalid_scan_row, "not-a-valid-row"}}
  end

  test "excludes Apple and system apps" do
    refute Unresponsive.eligible?(%{
             activation_policy: 0,
             bundle_id: "com.apple.TextEdit",
             bundle_path: "/System/Applications/TextEdit.app"
           })

    refute Unresponsive.eligible?(%{
             activation_policy: 0,
             bundle_id: "com.example.tool",
             bundle_path: "/System/Applications/Tool.app"
           })
  end

  test "keeps third-party apps" do
    app = %{
      activation_policy: 0,
      bundle_id: "com.example.writer",
      bundle_path: "/Applications/Writer.app"
    }

    assert Unresponsive.eligible?(app)
    assert Unresponsive.recovery_mode(app) == :automatic
  end

  test "keeps CursorUIViewService as an automatic system service" do
    app = %{
      activation_policy: 2,
      bundle_id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      bundle_path:
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc"
    }

    assert Unresponsive.eligible?(app)
    assert Unresponsive.recovery_mode(app) == :automatic
  end

  test "requires the exact CursorUIViewService system identity" do
    refute Unresponsive.eligible?(%{
             activation_policy: 2,
             bundle_id: "com.apple.TextInputUI.xpc.CursorUIViewService",
             bundle_path: "/Applications/CursorUIViewService.xpc"
           })
  end

  test "keeps only the exact CursorUIViewService recovery silent" do
    service = %{
      activation_policy: 2,
      bundle_id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      bundle_path:
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc"
    }

    assert Unresponsive.silent_recovery?(service)
    refute Unresponsive.silent_recovery?(%{service | bundle_path: "/Applications/Fake.xpc"})
  end

  test "finds a replacement PID and ignores the stopped PID" do
    assert Unresponsive.replacement_pid("805\n912\n", 805) == 912
    assert Unresponsive.replacement_pid("805\n", 805) == nil
    assert Unresponsive.replacement_pid("", 805) == nil
  end

  test "restarts CursorUIViewService through its current-user launchd job" do
    parent = self()

    runner = fn command, args ->
      send(parent, {:command, command, args})

      case {command, args} do
        {"kill", ["-TERM", "805"]} ->
          {"", 0}

        {"kill", ["-0", "805"]} ->
          {"", 1}

        {"id", ["-u"]} ->
          {"501\n", 0}

        {"launchctl", ["kickstart", "user/501/com.apple.TextInputUI.xpc.CursorUIViewService"]} ->
          {"", 0}

        {"pgrep", ["-x", "CursorUIViewService"]} ->
          {"912\n", 0}
      end
    end

    service = %{
      id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      name: "CursorUIViewService",
      pid: 805,
      recovery: :automatic,
      activation_policy: 2,
      bundle_id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      bundle_path:
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc"
    }

    assert Unresponsive.restart(service, runner, fn _duration -> flunk("unexpected sleep") end) ==
             :ok

    assert_receive {:command, "kill", ["-TERM", "805"]}
    assert_receive {:command, "kill", ["-0", "805"]}
    assert_receive {:command, "id", ["-u"]}

    assert_receive {:command, "launchctl",
                    ["kickstart", "user/501/com.apple.TextInputUI.xpc.CursorUIViewService"]}

    assert_receive {:command, "pgrep", ["-x", "CursorUIViewService"]}
    refute_received {:command, _command, _args}
  end
end
