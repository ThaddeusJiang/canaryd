defmodule Canaryd.SimulatorsTest do
  use ExUnit.Case, async: true

  alias Canaryd.Simulators

  test "parses booted devices with runtime and last-used timestamps" do
    output = """
    == Devices ==
    -- iOS 26.5 --
        iPhone 17 Pro (3ab52c32-12fe-4d58-9971-1b831fa30057) (Booted)
    -- watchOS 26.5 --
        Apple Watch Ultra 3 (2CB6293C-6DE6-46CC-9E3F-087EA247C771) (Booted)
    """

    timestamps = %{
      "3AB52C32-12FE-4D58-9971-1B831FA30057" => ~U[2026-08-12 23:59:50Z],
      "2CB6293C-6DE6-46CC-9E3F-087EA247C771" => ~U[2026-08-13 01:50:55Z]
    }

    reader = fn udid -> {:ok, Map.fetch!(timestamps, udid)} end

    assert [iphone, watch] = Simulators.parse_booted_devices(output, reader)

    assert iphone == %{
             udid: "3AB52C32-12FE-4D58-9971-1B831FA30057",
             name: "iPhone 17 Pro",
             runtime: "iOS 26.5",
             state: :booted,
             last_used_at: ~U[2026-08-12 23:59:50Z]
           }

    assert watch.runtime == "watchOS 26.5"
    assert watch.name == "Apple Watch Ultra 3"
  end

  test "keeps a device visible but non-actionable when its timestamp is unavailable" do
    output = """
    == Devices ==
    -- iOS 26.5 --
        Custom Phone (3AB52C32-12FE-4D58-9971-1B831FA30057) (Booted)
        malformed row
    """

    assert [%{name: "Custom Phone", last_used_at: nil}] =
             Simulators.parse_booted_devices(output, fn _udid ->
               {:error, :invalid_timestamp}
             end)
  end

  test "parses CoreSimulator ISO 8601 timestamps" do
    assert {:ok, ~U[2026-08-12 23:59:50Z]} =
             Simulators.parse_last_used_at("2026-08-12T23:59:50Z\n")

    assert {:error, :invalid_timestamp} = Simulators.parse_last_used_at("not a date")
  end

  test "finds only current-user xcodebuild and xctest processes" do
    output = """
      42 501 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
      43 501 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
      44 501 /usr/bin/simctl
      45 502 /usr/bin/xcodebuild
      malformed
    """

    assert Simulators.parse_automation_processes(output, 501) == [
             %{pid: 42, name: "xcodebuild"},
             %{pid: 43, name: "xctest"}
           ]
  end

  test "shuts down only the revalidated exact UDID" do
    device = device()
    scan = fn -> {:ok, [device]} end

    command = fn bin, args ->
      send(self(), {:command, bin, args})
      {:ok, ""}
    end

    assert :ok = Simulators.shutdown(device, scan, command)

    assert_received {:command, "xcrun",
                     [
                       "simctl",
                       "shutdown",
                       "3AB52C32-12FE-4D58-9971-1B831FA30057"
                     ]}
  end

  test "does not run a command after device activity or shutdown" do
    device = device()
    command = fn _bin, _args -> flunk("shutdown command must not run") end

    changed = %{device | last_used_at: ~U[2026-08-13 00:00:00Z]}

    assert {:error, :device_activity_changed} =
             Simulators.shutdown(device, fn -> {:ok, [changed]} end, command)

    assert :already_stopped = Simulators.shutdown(device, fn -> {:ok, []} end, command)
  end

  defp device do
    %{
      udid: "3AB52C32-12FE-4D58-9971-1B831FA30057",
      name: "iPhone 17 Pro",
      runtime: "iOS 26.5",
      state: :booted,
      last_used_at: ~U[2026-08-12 23:59:50Z]
    }
  end
end
