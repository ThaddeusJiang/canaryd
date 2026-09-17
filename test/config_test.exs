defmodule Canaryd.ConfigTest do
  use ExUnit.Case, async: true
  alias Canaryd.{Config, Duration}

  setup do
    home = Path.join("/private/tmp", "canaryd-config-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    %{options: [home: home, env: %{}], home: home}
  end

  test "works without any config file", %{options: options} do
    assert {:ok, config} = Config.resolve([], options)
    assert config.check_interval == Duration.minutes(5)
    assert config.cleanup_at == %{hour: 4, minute: 0}
    assert config.build_retention == Duration.hours(24)
    refute config.retention_override
  end

  test "flags override environment, saved retention and defaults", c do
    Canaryd.BuildCleanupConfig.set("72h", c.home)

    options =
      Keyword.put(c.options, :env, %{
        "CANARYD_BUILD_RETENTION" => "48h",
        "CANARYD_CHECK_INTERVAL" => "10m"
      })

    assert {:ok, config} = Config.resolve([build_retention: "36h", cleanup_at: "23:45"], options)
    assert config.build_retention == Duration.hours(36)
    assert config.check_interval == Duration.minutes(10)
    assert config.cleanup_at == %{hour: 23, minute: 45}
    assert config.retention_override
    assert {:ok, config} = Config.resolve([], c.options)
    assert config.build_retention == Duration.hours(72)
    refute config.retention_override
  end

  test "a higher priority flag bypasses invalid lower priority values", c do
    options = Keyword.put(c.options, :env, %{"CANARYD_CHECK_INTERVAL" => "broken"})
    assert {:ok, _} = Config.resolve([check_interval: "1m"], options)
  end

  test "rejects invalid values without side effects", c do
    for overrides <- [
          [check_interval: "0s"],
          [check_interval: "1"],
          [cleanup_at: "24:00"],
          [cleanup_at: "4:00"],
          [build_retention: "0h"],
          [build_retention: "1m"]
        ] do
      assert {:error, _} = Config.resolve(overrides, c.options)
      refute File.exists?(c.home)
    end
  end
end
