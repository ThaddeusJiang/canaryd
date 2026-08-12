defmodule Canaryd.MemoryProcessesTest do
  use ExUnit.Case, async: true

  alias Canaryd.MemoryProcesses

  test "parses registered applications and URI-decoded fields" do
    output =
      "42\t0\t0\tNowledge%20Mem\tcom.example.memory\t%2FApplications%2FNowledge%20Mem.app\n"

    assert {:ok,
            [
              %{
                id: "com.example.memory",
                name: "Nowledge Mem",
                pid: 42,
                activation_policy: 0,
                active: false,
                bundle_id: "com.example.memory",
                bundle_path: "/Applications/Nowledge Mem.app"
              }
            ]} = MemoryProcesses.parse_running_apps(output)
  end

  test "aggregates an app process tree and protects active or system apps" do
    apps = [
      app(),
      app(%{
        id: "com.example.active",
        name: "Active",
        pid: 84,
        active: true,
        bundle_id: "com.example.active",
        bundle_path: "/Applications/Active.app"
      }),
      app(%{
        id: "com.apple.systemsettings",
        name: "Settings",
        pid: 99,
        bundle_id: "com.apple.systemsettings",
        bundle_path: "/Applications/Settings.app"
      }),
      app(%{
        id: "com.example.helper",
        name: "Helper",
        pid: 101,
        bundle_id: "com.example.helper",
        bundle_path: "/Applications/Cache.app/Contents/Frameworks/Helper.app"
      })
    ]

    output = """
      42 501 0.2 100000 /Applications/Cache.app/Contents/MacOS/Cache
      43 501 0.3 1000000 /Applications/Cache.app/Contents/Resources/backend
      44 502 0.2 900000 /Applications/Cache.app/Contents/Resources/other-user
      84 501 0.1 1200000 /Applications/Active.app/Contents/MacOS/Active
      99 501 0.1 1300000 /Applications/Settings.app/Contents/MacOS/Settings
      101 501 0.1 1400000 /Applications/Cache.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper
    """

    assert [cache, settings, active] = MemoryProcesses.parse_processes(output, 501, apps)

    assert cache.id == "com.example.cache"
    assert cache.rss_mb == 2_441.4
    assert cache.cpu_percent == 0.6
    assert cache.actionable

    assert active.id == "com.example.active"
    refute active.actionable

    assert settings.id == "com.apple.systemsettings"
    refute settings.actionable
  end

  test "allows top-level apps in the user Applications directory" do
    app =
      app(%{
        bundle_path: "/Users/amami/Applications/Cache.app"
      })

    output =
      "42 501 0.1 1100000 /Users/amami/Applications/Cache.app/Contents/MacOS/Cache\n"

    assert [%{actionable: true}] = MemoryProcesses.parse_processes(output, 501, [app])
  end

  test "rejects malformed application output" do
    assert {:error, :invalid_output} = MemoryProcesses.parse_running_apps("malformed")
  end

  defp app(overrides \\ %{}) do
    Map.merge(
      %{
        id: "com.example.cache",
        name: "Cache",
        pid: 42,
        activation_policy: 0,
        active: false,
        bundle_id: "com.example.cache",
        bundle_path: "/Applications/Cache.app"
      },
      overrides
    )
  end
end
