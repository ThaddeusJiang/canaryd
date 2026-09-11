defmodule Canaryd.SimulatorMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, SimulatorMonitor}

  @t0 ~U[2026-08-14 00:00:00Z]

  defp later(value), do: Duration.add(@t0, Duration.minutes(value))

  defp device(overrides \\ %{}) do
    Map.merge(
      %{
        udid: "3AB52C32-12FE-4D58-9971-1B831FA30057",
        name: "iPhone 17 Pro",
        runtime: "iOS 26.5",
        state: :booted,
        last_used_at: Duration.add(@t0, -Duration.minutes(15))
      },
      overrides
    )
  end

  test "exposes the fixed Simulator inactivity threshold" do
    assert SimulatorMonitor.minimum_idle() == 900_000
  end

  test "shuts down on the first eligible check after 15 minutes" do
    {_state, actions} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], false, false, @t0)

    assert actions == [{:shutdown, device()}]
  end

  test "bringing Simulator to the foreground starts a new 15-minute window" do
    {state, []} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], true, false, @t0)

    assert state.last_foreground_at == @t0

    {state, []} = SimulatorMonitor.evaluate(state, [device()], false, false, later(14))

    {_state, actions} = SimulatorMonitor.evaluate(state, [device()], false, false, later(15))
    assert actions == [{:shutdown, device()}]
  end

  test "test automation blocks shutdown only while it is active" do
    {state, []} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], false, true, @t0)

    {_state, actions} = SimulatorMonitor.evaluate(state, [device()], false, false, later(5))
    assert actions == [{:shutdown, device()}]
  end

  test "recent, unavailable, and stopped devices are protected" do
    recent = device(%{last_used_at: Duration.add(@t0, -Duration.minutes(14))})
    unavailable = device(%{last_used_at: nil})
    stopped = device(%{state: :shutdown})

    {_state, actions} =
      SimulatorMonitor.evaluate(
        SimulatorMonitor.default_state(),
        [recent, unavailable, stopped],
        false,
        false,
        @t0
      )

    assert actions == []
  end

  test "a changed last-used timestamp starts a new 15-minute window" do
    state = SimulatorMonitor.default_state()
    changed = device(%{last_used_at: later(5)})

    {state, []} = SimulatorMonitor.evaluate(state, [changed], false, false, later(19))

    {_state, actions} = SimulatorMonitor.evaluate(state, [changed], false, false, later(20))
    assert actions == [{:shutdown, changed}]
  end

  test "ignores persisted confirmation rounds from the previous policy" do
    legacy_state = %{
      observations: %{device().udid => %{device: device(), count: 2}}
    }

    {state, actions} = SimulatorMonitor.evaluate(legacy_state, [device()], false, false, @t0)

    assert actions == [{:shutdown, device()}]
    assert state.observations == %{}
    assert state.last_foreground_at == nil
  end
end
