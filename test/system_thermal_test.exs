defmodule Canaryd.SystemThermalTest do
  use ExUnit.Case, async: true

  alias Canaryd.{PolicyConfig, System}

  test "high load triggers thermal monitoring below the temperature threshold" do
    system = sample()
    assert system.load1 == 37.03
    assert system.cores == 10
    assert system.thermal_pressure
    assert system.thermal_status == :high
    assert [%{pid: 42}] = system.hot_processes
  end

  test "load-only notification names the cause below the temperature threshold" do
    {title, body} = System.pressure_notification(sample())
    assert title == "Mac high load warning"
    assert body =~ "load1 37.03 > 8.0 (10 cores)"
    assert body =~ "CPU 64.0°C"
  end

  test "temperature notification retains concurrent load evidence" do
    {title, body} = System.pressure_notification(sample(%{}, 75.0))
    assert title == "Mac temperature warning"
    assert body =~ "CPU temperature 75.0°C"
    assert body =~ "load1 37.03 > 8.0 (10 cores)"
  end

  test "throttling notification names throttling when sensors are unavailable" do
    system = sample(%{{"pmset", ["-g", "therm"]} => {:ok, "CPU_Speed_Limit = 80"}}, :unavailable)
    {title, body} = System.pressure_notification(system)
    assert title == "Mac thermal throttling warning"
    assert body =~ "CPU thermal throttling active"
    assert body =~ "CPU/GPU temperature unavailable"
  end

  test "unrelated memory warnings do not become pressure triggers" do
    system = sample(%{{"memory_pressure", []} => {:ok, "System-wide memory free percentage: 5%"}})
    assert "memory free 5%" in system.warnings
    refute "memory free 5%" in system.pressure_warnings
  end

  test "configured temperature, load and suspect CPU thresholds change the live classification" do
    low_load = %{{"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 1.0 1.0 1.0 }"}}

    policy = %{
      PolicyConfig.defaults()
      | system_chip_temperature: 60.0,
        system_hot_process_cpu: 90.0
    }

    system = sample(low_load, 65.0, policy: policy)
    assert system.thermal_pressure
    assert system.hot_processes == []

    policy = %{policy | system_chip_temperature: 80.0, system_load_factor: 0.05}
    system = sample(low_load, 65.0, policy: policy)
    assert system.thermal_pressure
    assert Enum.any?(system.warnings, &String.contains?(&1, "load1"))
  end

  test "failed or invalid load samples are unavailable rather than zero or healthy" do
    for {metric, result} <- [
          {"vm.loadavg", {:error, :unavailable}},
          {"hw.ncpu", {:error, :unavailable}},
          {"vm.loadavg", {:ok, "invalid"}},
          {"vm.loadavg", {:ok, "{ -1.0 0.0 0.0 }"}},
          {"hw.ncpu", {:ok, "0"}},
          {"hw.ncpu", {:ok, "invalid"}}
        ] do
      system = sample(%{{"sysctl", ["-n", metric]} => result})
      assert system.load1 == nil
      assert system.cores == nil
      assert system.load_per_core == nil
      assert system.thermal_status == :unavailable
      refute system.thermal_pressure
      assert "system load unavailable" in system.warnings
      output = Canaryd.CLI.thermal_summary(system)
      assert output =~ "thermal pressure: unavailable"
      assert output =~ "system load unavailable"
      refute output =~ "normal"
    end
  end

  test "missing load does not suppress independently observed heat" do
    system = sample(%{{"sysctl", ["-n", "vm.loadavg"]} => {:error, :unavailable}}, 75.0)
    assert system.thermal_pressure
    assert system.thermal_status == :high
    assert [%{pid: 42}] = system.hot_processes
    assert Canaryd.CLI.thermal_summary(system) =~ "system load unavailable"
  end

  test "missing temperature or throttling data is not reported as normal" do
    normal_load = %{{"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 1.0 1.0 1.0 }"}}

    for system <- [
          sample(normal_load, :unavailable),
          sample(Map.put(normal_load, {"pmset", ["-g", "therm"]}, {:error, :unavailable})),
          sample(Map.put(normal_load, {"pmset", ["-g", "therm"]}, {:ok, "invalid"}))
        ] do
      assert system.thermal_status == :unavailable
      refute Canaryd.CLI.thermal_summary(system) =~ "normal"
    end
  end

  test "successful cool and low-load samples are normal" do
    system = sample(%{{"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 1.0 1.0 1.0 }"}})
    assert system.thermal_status == :normal
    refute system.thermal_pressure
    assert system.warnings == []
    assert Canaryd.CLI.thermal_summary(system) =~ "thermal pressure: normal"
  end

  test "includes disk and swap samples when supplied" do
    system =
      sample(
        %{{"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 1.0 1.0 1.0 }"}},
        64.0,
        disk_sampler: fn -> {:ok, %{used_percent: 96, available_bytes: 4_000}} end,
        swap_sampler: fn -> {:ok, %{total_bytes: 10, used_bytes: 8, free_bytes: 2}} end
      )

    assert system.disk_usage.used_percent == 96
    assert system.swap_usage.used_bytes == 8
    assert "disk available 3.9 KB" in system.warnings
  end

  test "disk warning uses the configured available-space threshold" do
    options = [
      disk_sampler: fn ->
        {:ok, %{used_percent: 96, available_bytes: 15 * 1_024 * 1_024 * 1_024}}
      end
    ]

    normal_load = %{{"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 1.0 1.0 1.0 }"}}

    below_threshold =
      sample(
        normal_load,
        64.0,
        Keyword.put(options, :disk_threshold, {:ok, 10 * 1_024 * 1_024 * 1_024})
      )

    refute Enum.any?(below_threshold.warnings, &String.starts_with?(&1, "disk available"))

    under_pressure =
      sample(
        normal_load,
        64.0,
        Keyword.put(options, :disk_threshold, {:ok, 20 * 1_024 * 1_024 * 1_024})
      )

    assert "disk available 15.0 GB" in under_pressure.warnings

    invalid =
      sample(
        normal_load,
        64.0,
        Keyword.put(options, :disk_threshold, {:error, :invalid_threshold})
      )

    assert "storage threshold unavailable: :invalid_threshold" in invalid.warnings
  end

  defp sample(overrides \\ %{}, temperature \\ 64.0, options \\ []) do
    responses = %{
      {"sysctl", ["-n", "hw.ncpu"]} => {:ok, "10\n"},
      {"sysctl", ["-n", "vm.loadavg"]} => {:ok, "{ 37.03 35.0 26.0 }"},
      {"pmset", ["-g", "therm"]} => {:ok, "Note: No CPU power status has been recorded"},
      {"memory_pressure", []} => {:ok, "System-wide memory free percentage: 30%"},
      {"ioreg", ["-r", "-n", "AppleSmartBattery"]} => {:ok, ""},
      {"id", ["-u"]} => {:ok, "501"},
      {"ps", ["-Ao", "pid=,uid=,pcpu=,command="]} => {:ok, "42 501 80.0 /usr/bin/node"}
    }

    responses = Map.merge(responses, overrides)

    System.check(
      runner: fn command, args -> Map.fetch!(responses, {command, args}) end,
      temperature_sampler: fn ->
        if temperature == :unavailable,
          do: {:error, :unavailable},
          else: {:ok, %{cpu_temperature_c: temperature, gpu_temperature_c: temperature}}
      end,
      disk_sampler: Keyword.get(options, :disk_sampler, fn -> {:error, :unavailable} end),
      swap_sampler: Keyword.get(options, :swap_sampler, fn -> {:error, :unavailable} end),
      disk_threshold: Keyword.get(options, :disk_threshold, {:ok, 20 * 1_024 * 1_024 * 1_024}),
      policy: Keyword.get(options, :policy, PolicyConfig.defaults())
    )
  end

  test "converts HID idle nanoseconds to the internal millisecond unit" do
    assert System.parse_idle_duration(~s("HIDIdleTime" = 1800000000000)) == 1_800_000
    assert System.parse_idle_duration("missing") == 0
  end

  test "parses battery temperature in tenths of kelvin" do
    output = ~s("Temperature" = 3131)
    assert System.parse_battery_temperature(output) == 40.0
  end

  test "uses CPU or GPU sensor temperature for chip thermal pressure" do
    refute System.chip_temperature_pressure?(%{
             cpu_temperature_c: 69.9,
             gpu_temperature_c: 69.9
           })

    assert System.chip_temperature_pressure?(%{
             cpu_temperature_c: 70.0,
             gpu_temperature_c: 60.0
           })

    assert System.chip_temperature_pressure?(%{
             cpu_temperature_c: 60.0,
             gpu_temperature_c: 70.0
           })
  end

  test "formats exact sensor temperatures separately from battery temperature" do
    assert System.temperature_summary(%{
             temperature_source: :macmon,
             cpu_temperature_c: 71.2,
             gpu_temperature_c: 68.9,
             battery_temperature_c: 40.5
           }) == "CPU 71.2°C; GPU 68.9°C; battery 40.5°C"
  end

  test "omits unavailable battery temperature" do
    assert System.temperature_summary(%{
             temperature_source: :macmon,
             cpu_temperature_c: 74.7,
             gpu_temperature_c: 74.5,
             battery_temperature_c: nil
           }) == "CPU 74.7°C; GPU 74.5°C"
  end

  test "reports unavailable chip sensors without hiding battery temperature" do
    assert System.temperature_summary(%{
             temperature_source: :unavailable,
             cpu_temperature_c: nil,
             gpu_temperature_c: nil,
             battery_temperature_c: 40.5
           }) == "CPU/GPU temperature unavailable; battery 40.5°C"
  end

  test "omits battery text when all temperature sensors are unavailable" do
    assert System.temperature_summary(%{
             temperature_source: :unavailable,
             cpu_temperature_c: nil,
             gpu_temperature_c: nil,
             battery_temperature_c: nil
           }) == "CPU/GPU temperature unavailable"
  end

  test "parses high CPU processes and protects system processes" do
    output = """
      42   501  88.5 /Applications/Render.app/Contents/MacOS/Render
      43   501  80.0 /Applications/Render.app/Contents/Frameworks/Render Helper.app/Contents/MacOS/Render Helper
      99     0  72.0 /System/Library/kernel_task
    """

    assert [
             %{
               pid: 42,
               cpu_percent: 88.5,
               name: "Render",
               bundle_path: "/Applications/Render.app",
               actionable: true
             },
             %{pid: 43, name: "Render", actionable: false},
             %{pid: 99, name: "kernel_task", actionable: false}
           ] = System.parse_hot_processes(output, 501)
  end
end
