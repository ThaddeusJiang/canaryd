defmodule Canaryd.NotifierTest do
  use ExUnit.Case, async: true

  alias Canaryd.Notifier

  test "parses interactive app actions" do
    assert Notifier.parse_app_action("restart\n") == {:ok, :restart}
    assert Notifier.parse_app_action("close\n") == {:ok, :close}
    assert Notifier.parse_app_action("ignore\n") == {:ok, :ignore}
    assert Notifier.parse_app_action("unknown\n") == {:error, :invalid_action}
  end

  test "sends an informational notification through the Canaryd helper" do
    caller = self()

    runner = fn bin, args ->
      send(caller, {:command, bin, args})
      {"scheduled\n", 0}
    end

    assert Notifier.notify("Mac Health", "CleanClip needs attention.", runner) == :ok

    assert_receive {:command, helper, args}
    assert helper == Canaryd.NotificationHelper.executable_path()

    assert args == [
             "notify",
             "Mac Health",
             "CleanClip needs attention.",
             "30"
           ]
  end

  test "sends a persistent temperature warning notification" do
    caller = self()

    runner = fn bin, args ->
      send(caller, {:command, bin, args})
      {"scheduled\n", 0}
    end

    assert Notifier.warn_temperature("CPU 74.6°C; GPU 72.3°C", runner) == :ok

    assert_receive {:command, helper, args}
    assert helper == Canaryd.NotificationHelper.executable_path()

    assert args == [
             "notify",
             "Mac temperature warning",
             "CPU 74.6°C; GPU 72.3°C",
             "30"
           ]
  end

  test "reports a temperature warning notification failure" do
    runner = fn _bin, _args -> {"not permitted", 1} end

    assert Notifier.warn_temperature("CPU 74.6°C", runner) ==
             {:error, {:notification_failed, "not permitted"}}
  end

  test "asks for an app action in a notification" do
    caller = self()

    runner = fn bin, args ->
      send(caller, {:command, bin, args})
      {"restart\n", 0}
    end

    assert Notifier.choose_app_action("CursorUIViewService", runner) == {:ok, :restart}

    assert_receive {:command, helper, args}
    assert helper == Canaryd.NotificationHelper.executable_path()

    assert args == [
             "action",
             "Mac Health",
             "CursorUIViewService is not responding. Close or Restart can force-stop this instance. macOS opens the service again when needed.",
             "120"
           ]
  end

  test "asks for a thermal action in a notification" do
    runner = fn _bin, args ->
      assert args == [
               "action",
               "Mac temperature is high",
               "Code is the leading CPU-related heat suspect.\nCPU 75.0°C\nCPU usage is correlation evidence. Close or Restart can discard unsaved data.",
               "120"
             ]

      {"close\n", 0}
    end

    assert Notifier.choose_thermal_action("Code", "CPU 75.0°C", runner) == {:ok, :close}
  end
end
