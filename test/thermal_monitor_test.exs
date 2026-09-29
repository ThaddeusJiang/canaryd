defmodule Canaryd.ThermalMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, PolicyConfig, ThermalMonitor}

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

  test "changing protected PIDs shares the warning cooldown" do
    first = app(%{id: "rustc:42", actionable: false})
    second = app(%{id: "rustc:43", actionable: false})

    {state, [{:report, _}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [first], @t0)

    {state, []} = ThermalMonitor.evaluate(state, true, [second], later(300))
    {_state, [{:report, [^second]}]} = ThermalMonitor.evaluate(state, true, [second], later(900))
  end

  test "configured cooldowns apply across different processes" do
    policy = %{
      PolicyConfig.defaults()
      | thermal_alert_cooldown: Duration.minutes(1),
        thermal_prompt_cooldown: Duration.minutes(20)
    }

    first = app(%{id: "rustc:42", actionable: false})
    second = app(%{id: "rustc:43", actionable: false})

    {state, [{:report, _}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [first], @t0, policy)

    {state, []} = ThermalMonitor.evaluate(state, true, [second], later(30), policy)

    {_state, [{:report, [^second]}]} =
      ThermalMonitor.evaluate(state, true, [second], later(60), policy)

    state = %{ThermalMonitor.default_state() | prompts: %{"prior" => @t0}}
    {state, [{:report, _}]} = ThermalMonitor.evaluate(state, true, [app()], later(300), policy)
    {state, [{:alert, _, _}]} = ThermalMonitor.evaluate(state, true, [app()], later(1200), policy)

    {_state, [{:choose, _, _}]} =
      ThermalMonitor.evaluate(state, true, [app()], later(1500), policy)
  end

  test "changing actionable apps shares the warning and prompt cooldowns" do
    other = app(%{id: "/Applications/Other.app"})

    {state, [{:alert, _, _}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)

    {state, []} = ThermalMonitor.evaluate(state, true, [other], later(300))
    {state, [{:choose, ^other, _}]} = ThermalMonitor.evaluate(state, true, [other], later(600))
    {_state, []} = ThermalMonitor.evaluate(state, true, [app()], later(900))
  end

  test "protected and actionable candidates share the warning cooldown" do
    protected = app(%{id: "rustc:42", actionable: false})

    {state, [{:report, _}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [protected], @t0)

    {_state, []} = ThermalMonitor.evaluate(state, true, [app()], later(300))
  end

  test "reports pressure even when no process crosses the CPU threshold" do
    {state, [{:report, []}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [], @t0)

    {_state, []} = ThermalMonitor.evaluate(state, true, [], later(300))
  end

  test "an empty suspect list breaks actionable confirmation without ending pressure" do
    {state, _} = ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)
    {state, []} = ThermalMonitor.evaluate(state, true, [], later(300))
    {_state, []} = ThermalMonitor.evaluate(state, true, [app()], later(600))
  end

  test "legacy per-process alert times preserve the shared cooldown" do
    state = %{observations: %{}, alerts: %{"old:1" => @t0}, prompts: %{}}
    {_state, []} = ThermalMonitor.evaluate(state, true, [app()], later(300))
  end

  test "legacy alert and prompt entries for the same app retain the latest warning" do
    state = %{
      observations: %{},
      alerts: %{app().id => later(4200)},
      prompts: %{app().id => @t0}
    }

    {_state, []} = ThermalMonitor.evaluate(state, true, [app()], later(4500))
  end

  test "prompt cooldown does not hide subsequent pressure reminders" do
    {state, _} = ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [app()], @t0)
    {state, [{:choose, _, _}]} = ThermalMonitor.evaluate(state, true, [app()], later(300))
    {_state, [{:report, _}]} = ThermalMonitor.evaluate(state, true, [app()], later(1200))
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
