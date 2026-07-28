defmodule Canaryd.SystemThermalTest do
  use ExUnit.Case, async: true

  alias Canaryd.System

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
           }) == "CPU 71.2 C; GPU 68.9 C; battery 40.5 C"
  end

  test "reports unavailable chip sensors without hiding battery temperature" do
    assert System.temperature_summary(%{
             temperature_source: :unavailable,
             cpu_temperature_c: nil,
             gpu_temperature_c: nil,
             battery_temperature_c: 40.5
           }) == "CPU/GPU temperature unavailable; battery 40.5 C"
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
