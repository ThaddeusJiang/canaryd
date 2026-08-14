defmodule Canaryd.RuntimePathsTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Paths, Store}
  alias Canaryd.Apps.CleanClip

  setup do
    original_home = System.get_env("HOME")

    runtime_home =
      Path.join(System.tmp_dir!(), "canaryd-runtime-home-#{System.unique_integer([:positive])}")

    System.put_env("HOME", runtime_home)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    %{runtime_home: runtime_home}
  end

  test "resolves every user-specific path from the runtime home", %{runtime_home: runtime_home} do
    assert Store.dir() ==
             Path.join([runtime_home, "Library", "Application Support", "canaryd"])

    assert Paths.launch_agents_dir() == Path.join([runtime_home, "Library", "LaunchAgents"])

    assert Paths.simulator_devices_dir() ==
             Path.join([runtime_home, "Library", "Developer", "CoreSimulator", "Devices"])

    assert CleanClip.history_dir() ==
             Path.join([
               runtime_home,
               "Library",
               "Application Support",
               "com.antiless.cleanclip.mac",
               "PrivateData",
               "HistoryItemContents"
             ])
  end
end
