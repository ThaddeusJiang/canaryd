defmodule Canaryd.DiskPressureMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{DiskPressureMonitor, Duration}

  @t0 ~U[2026-09-23 00:00:00Z]

  defp usage(available_gib),
    do: %{used_percent: 50, available_bytes: available_gib * 1_024 * 1_024 * 1_024}

  test "triggers once on entry and again only after cooldown" do
    {state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(DiskPressureMonitor.default_state(), usage(19), @t0)

    {state, []} =
      DiskPressureMonitor.evaluate(state, usage(19), Duration.add(@t0, Duration.minutes(5)))

    {state, []} =
      DiskPressureMonitor.evaluate(state, usage(19), Duration.add(@t0, Duration.minutes(59)))

    {_state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(state, usage(19), Duration.add(@t0, Duration.minutes(60)))
  end

  test "recovery does not bypass cooldown when free space oscillates" do
    {state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(DiskPressureMonitor.default_state(), usage(19), @t0)

    {state, []} =
      DiskPressureMonitor.evaluate(state, usage(20), Duration.add(@t0, Duration.minutes(5)))

    {state, []} =
      DiskPressureMonitor.evaluate(state, usage(19), Duration.add(@t0, Duration.minutes(10)))

    {_state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(state, usage(19), Duration.add(@t0, Duration.minutes(60)))
  end

  test "ignores used percentage when enough space is available" do
    {state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(DiskPressureMonitor.default_state(), usage(19), @t0)

    {state, []} =
      DiskPressureMonitor.evaluate(
        state,
        %{used_percent: 99, available_bytes: 25 * 1_024 * 1_024 * 1_024},
        Duration.add(@t0, Duration.minutes(5))
      )

    refute state.active
  end

  test "healthy usage stays inactive and a changed threshold takes effect" do
    {state, []} =
      DiskPressureMonitor.evaluate(
        DiskPressureMonitor.default_state(),
        usage(15),
        @t0,
        10 * 1_024 * 1_024 * 1_024
      )

    refute state.active

    {_state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(
        state,
        usage(15),
        Duration.add(@t0, Duration.minutes(5)),
        20 * 1_024 * 1_024 * 1_024
      )
  end

  test "crossing the emergency free-space threshold bypasses normal cleanup cooldown" do
    policy = Canaryd.PolicyConfig.defaults()

    {state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(
        DiskPressureMonitor.default_state(),
        usage(9),
        @t0,
        10 * 1_024 * 1_024 * 1_024,
        policy
      )

    emergency_usage = %{used_percent: 99, available_bytes: 900 * 1_024 * 1_024}

    {state, [{:emergency_cleanup, ^emergency_usage}]} =
      DiskPressureMonitor.evaluate(
        state,
        emergency_usage,
        Duration.add(@t0, Duration.minutes(1)),
        10 * 1_024 * 1_024 * 1_024,
        policy
      )

    {_state, []} =
      DiskPressureMonitor.evaluate(
        state,
        emergency_usage,
        Duration.add(@t0, Duration.minutes(2)),
        10 * 1_024 * 1_024 * 1_024,
        policy
      )
  end

  test "invalid free-space samples do not start emergency deletion" do
    {_state, actions} =
      DiskPressureMonitor.evaluate(
        DiskPressureMonitor.default_state(),
        %{available_bytes: nil},
        @t0
      )

    assert actions == []
  end
end
