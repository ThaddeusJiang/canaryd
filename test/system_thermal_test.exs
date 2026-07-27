defmodule Canaryd.SystemThermalTest do
  use ExUnit.Case, async: true

  alias Canaryd.System

  test "parses battery temperature in tenths of kelvin" do
    output = ~s("Temperature" = 3131)
    assert System.parse_battery_temperature(output) == 40.0
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
