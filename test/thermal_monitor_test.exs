defmodule Canaryd.ThermalMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, ThermalMonitor}

  @t0 ~U[2026-07-27 00:00:00Z]

  defp later(value), do: Duration.add(@t0, Duration.seconds(value))

  defp app(overrides \\ %{}) do
    Map.merge(
      %{
        id: "/Applications/Render.app",
        name: "Render",
        pid: 42,
        cpu_percent: 88.5,
        bundle_path: "/Applications/Render.app",
        actionable: true
      },
      overrides
    )
  end

  test "asks after two consecutive hot observations" do
    {state, first_actions} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)

    assert first_actions == [{:alert, app(), [app()]}]

    {_state, second_actions} =
      ThermalMonitor.evaluate(state, true, [app()], later(300))

    assert second_actions == [{:choose, app(), [app()]}]
  end

  test "clears a pending observation when thermal pressure ends" do
    {state, _actions} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)

    {state, actions} =
      ThermalMonitor.evaluate(state, false, [app()], later(300))

    assert actions == []
    assert state.observations == %{}
  end

  test "reports but does not offer actions for protected processes" do
    process = app(%{id: "kernel_task", name: "kernel_task", bundle_path: nil, actionable: false})

    {_state, actions} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [process], @t0)

    assert actions == [{:report, [process]}]
  end

  test "does not repeat a prompt during cooldown" do
    {state, _actions} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)

    {state, [{:choose, _app, _suspects}]} =
      ThermalMonitor.evaluate(state, true, [app()], later(300))

    {_state, actions} =
      ThermalMonitor.evaluate(state, true, [app()], later(600))

    assert actions == []
  end

  test "does not repeat an alert during the alert cooldown" do
    {state, [{:alert, _app, _suspects}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)

    {state, []} =
      ThermalMonitor.evaluate(state, false, [], later(300))

    {state, actions} =
      ThermalMonitor.evaluate(state, true, [app()], later(600))

    assert actions == []

    {state, []} =
      ThermalMonitor.evaluate(state, false, [], later(900))

    {_state, actions} =
      ThermalMonitor.evaluate(state, true, [app()], later(901))

    assert actions == [{:alert, app(), [app()]}]
  end
end
