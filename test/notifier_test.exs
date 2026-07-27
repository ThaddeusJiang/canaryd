defmodule Canaryd.NotifierTest do
  use ExUnit.Case, async: true

  alias Canaryd.Notifier

  test "parses interactive app actions" do
    assert Notifier.parse_app_action("restart\n") == {:ok, :restart}
    assert Notifier.parse_app_action("close\n") == {:ok, :close}
    assert Notifier.parse_app_action("ignore\n") == {:ok, :ignore}
    assert Notifier.parse_app_action("unknown\n") == {:error, :invalid_action}
  end

  test "shows a time-limited temperature warning alert" do
    caller = self()

    runner = fn bin, args ->
      send(caller, {:command, bin, args})
      {"shown\n", 0}
    end

    assert Notifier.warn_temperature("CPU 74.6 C; GPU 72.3 C", runner) == :ok

    assert_receive {:command, "osascript", args}
    assert ["-e", script, "CPU 74.6 C; GPU 72.3 C"] = args
    assert script =~ "activateIgnoringOtherApps:true"
    assert script =~ ~s(display alert "Mac temperature warning")
    assert script =~ ~s(buttons {"Ignore"})
    assert script =~ "giving up after 30"
  end

  test "reports a temperature warning dialog failure" do
    runner = fn _bin, _args -> {"not permitted", 1} end

    assert Notifier.warn_temperature("CPU 74.6 C", runner) ==
             {:error, {:dialog_failed, "not permitted"}}
  end
end
