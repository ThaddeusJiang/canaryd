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
        last_used_at: Duration.add(@t0, -Duration.minutes(30))
      },
      overrides
    )
  end

  test "exposes conservative thresholds" do
    assert SimulatorMonitor.minimum_idle() == 1_800_000
    assert SimulatorMonitor.required_observations() == 3
  end

  test "shuts down after three consecutive idle observations" do
    idle = Duration.minutes(30)

    {state, actions} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], idle, false, @t0)

    assert actions == [{:detected, device(), 1}]

    {state, actions} = SimulatorMonitor.evaluate(state, [device()], idle, false, later(5))
    assert actions == [{:detected, device(), 2}]

    {state, actions} = SimulatorMonitor.evaluate(state, [device()], idle, false, later(10))
    assert actions == [{:shutdown, device()}]
    assert SimulatorMonitor.pending_devices(state) == []
  end

  test "user activity and test automation reset confirmation" do
    idle = Duration.minutes(30)

    {state, _actions} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], idle, false, @t0)

    {state, []} =
      SimulatorMonitor.evaluate(state, [device()], Duration.minutes(29), false, later(5))

    {state, actions} = SimulatorMonitor.evaluate(state, [device()], idle, false, later(10))
    assert actions == [{:detected, device(), 1}]

    {state, []} = SimulatorMonitor.evaluate(state, [device()], idle, true, later(15))
    {_state, actions} = SimulatorMonitor.evaluate(state, [device()], idle, false, later(20))
    assert actions == [{:detected, device(), 1}]
  end

  test "recent, unavailable, and stopped devices are protected" do
    recent = device(%{last_used_at: Duration.add(@t0, -Duration.minutes(29))})
    unavailable = device(%{last_used_at: nil})
    stopped = device(%{state: :shutdown})

    {_state, actions} =
      SimulatorMonitor.evaluate(
        SimulatorMonitor.default_state(),
        [recent, unavailable, stopped],
        Duration.minutes(30),
        false,
        @t0
      )

    assert actions == []
  end

  test "a changed last-used timestamp starts a new confirmation sequence" do
    idle = Duration.minutes(30)

    {state, _actions} =
      SimulatorMonitor.evaluate(SimulatorMonitor.default_state(), [device()], idle, false, @t0)

    changed = device(%{last_used_at: Duration.add(@t0, -Duration.minutes(31))})
    {_state, actions} = SimulatorMonitor.evaluate(state, [changed], idle, false, later(5))

    assert actions == [{:detected, changed, 1}]
  end
end
