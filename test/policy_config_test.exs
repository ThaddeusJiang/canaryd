defmodule Canaryd.PolicyConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.{CLI, Duration, PolicyConfig, Setup}

  setup do
    home = Path.join(System.tmp_dir!(), "canaryd-policy-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "all decision thresholds have validated defaults and stable CLI names", %{home: home} do
    assert {:ok, policy} = PolicyConfig.read_all(home)
    assert policy == PolicyConfig.defaults()
    assert policy.system_chip_temperature == 70.0
    assert policy.memory_rss == 1_024
    assert policy.swap_min_growth == 512
    assert policy.check_interval == 5
    assert policy.storage_emergency_threshold == 1_024
    assert length(PolicyConfig.keys()) == length(Enum.uniq(PolicyConfig.names()))
    assert Enum.all?(PolicyConfig.keys(), &(&1 == PolicyConfig.key(PolicyConfig.name(&1))))
  end

  test "persists numeric and duration settings without starting monitoring", %{home: home} do
    options = [home: home, start: fn -> flunk("config must not start monitoring") end]

    assert capture_io(fn -> CLI.main(["config", "swap-min-growth", "768M"], options) end) ==
             "swap-min-growth=768M\n"

    assert capture_io(fn -> CLI.main(["config", "system-chip-temperature", "75C"], options) end) ==
             "system-chip-temperature=75.0C\n"

    assert capture_io(fn -> CLI.main(["config", "thermal-alert-cooldown", "20m"], options) end) ==
             "thermal-alert-cooldown=20m\n"

    assert {:ok, policy} = PolicyConfig.read_all(home)
    assert policy.swap_min_growth == 768
    assert policy.system_chip_temperature == 75.0
    assert policy.thermal_alert_cooldown == Duration.minutes(20)

    assert {:ok, config} = Canaryd.Config.resolve([], home: home, env: %{})

    assert [%{calendar: _}] = Setup.agent_specs("/tmp/canaryd", config)

    assert capture_io(fn -> CLI.main(["config", "swap-min-growth"], options) end) ==
             "swap-min-growth=768M\n"

    refute capture_io(fn -> CLI.main(["config"], options) end) =~ "cleanup-time"
  end

  test "rejects invalid values without overwriting the last valid setting", %{home: home} do
    assert {:ok, 768} = PolicyConfig.set("swap-min-growth", "768M", home)

    for value <- ["0M", "63M", "9999999M", "768", "7.5M", "768MM", "768M\n512M", ""] do
      assert {:error, :invalid_value} = PolicyConfig.set("swap-min-growth", value, home)
      assert PolicyConfig.read(:swap_min_growth, home) == {:ok, 768}
    end

    assert {:error, :unknown_key} = PolicyConfig.set("cleanup-time", "05:30", home)
    assert {:error, :invalid_value} = PolicyConfig.set("playwright-confirmations", "1", home)
    assert {:error, :invalid_value} = PolicyConfig.set("storage-cleanup-cooldown", "1m", home)
    assert {:error, :invalid_value} = PolicyConfig.set("memory-rss", nil, home)
    assert {:error, :unknown_key} = PolicyConfig.set("made-up", "1", home)
  end

  test "emergency free-space threshold is configurable", %{home: home} do
    assert {:ok, 768} = PolicyConfig.set("storage-emergency-threshold", "768M", home)
    assert PolicyConfig.read(:storage_emergency_threshold, home) == {:ok, 768}
    assert {:error, :invalid_value} = PolicyConfig.set("storage-emergency-threshold", "0M", home)
    assert PolicyConfig.read(:storage_emergency_threshold, home) == {:ok, 768}
  end

  test "retired cleanup-time entry does not block an upgraded installation", %{home: home} do
    path = Canaryd.ConfigFile.path(home)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "cleanup-time=04:00\n")
    assert {:ok, _policy} = PolicyConfig.read_all(home)
    refute "cleanup-time" in PolicyConfig.names()
  end

  test "corrupt, oversized and symlinked settings fail closed", %{home: home} do
    path =
      Path.join([home, "Library", "Application Support", "canaryd", "thresholds", "memory-rss"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not-a-number")
    assert PolicyConfig.read_all(home) == {:error, {"memory-rss", :invalid_value}}

    File.write!(path, String.duplicate("1", 65))
    assert PolicyConfig.read_all(home) == {:error, {"memory-rss", :config_too_large}}

    File.rm!(path)
    File.ln_s!("/tmp/irrelevant", path)
    assert PolicyConfig.read_all(home) == {:error, {"memory-rss", :invalid_config_file}}
  end

  test "rejects incoherent spacing and schedule intervals", %{home: home} do
    assert {:error, :invalid_spacing_range} = PolicyConfig.set("memory-min-spacing", "15m", home)
    assert {:ok, _} = PolicyConfig.read_all(home)

    assert {:ok, _} = PolicyConfig.set("memory-max-gap", "20m", home)
    assert {:ok, _} = PolicyConfig.set("memory-min-spacing", "15m", home)
    assert {:ok, _} = PolicyConfig.read_all(home)

    assert {:error, :invalid_check_interval} = PolicyConfig.set("check-interval", "7m", home)

    assert {:ok, 1} = PolicyConfig.set("check-interval", "1m", home)

    assert {:error, :check_interval_exceeds_observation_gap} =
             PolicyConfig.set("check-interval", "15m", home)

    assert {:ok, _} = PolicyConfig.set("swap-min-spacing", "1m", home)
    assert {:ok, _} = PolicyConfig.set("build-process-min-spacing", "1m", home)
    assert {:ok, 1} = PolicyConfig.set("check-interval", "1m", home)
    assert {:ok, policy} = PolicyConfig.read_all(home)
    assert policy.check_interval == 1
    assert {:ok, config} = Canaryd.Config.resolve([], home: home, env: %{})
    assert length(hd(Setup.agent_specs("/tmp/canaryd", config)).calendar) == 60
  end
end
