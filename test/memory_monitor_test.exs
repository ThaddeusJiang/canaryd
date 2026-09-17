defmodule Canaryd.MemoryMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, MemoryMonitor}

  @t0 ~U[2026-08-13 00:00:00Z]

  defp later(value), do: Duration.add(@t0, Duration.minutes(value))

  defp app(overrides \\ %{}) do
    Map.merge(
      %{
        id: "com.example.cache",
        name: "Cache",
        pid: 42,
        rss_mb: 1_500.0,
        cpu_percent: 0.5,
        actionable: true,
        bundle_id: "com.example.cache",
        bundle_path: "/Applications/Cache.app"
      },
      overrides
    )
  end

  test "exposes conservative thresholds" do
    assert MemoryMonitor.memory_threshold_mb() == 1_024.0
    assert MemoryMonitor.cpu_threshold() == 1.0
    assert MemoryMonitor.required_observations() == 3
    assert MemoryMonitor.alert_cooldown() == 3_600_000
  end

  test "alerts after three high-memory observations while the user is active" do
    idle = 0

    {state, actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    assert actions == [{:detected, app(), 1}]

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(5))
    assert actions == [{:detected, app(), 2}]

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(10))
    assert actions == [{:alert, app()}]
    assert MemoryMonitor.pending_apps(state) == []
  end

  test "lower memory and CPU activity reset confirmation" do
    idle = 0

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {state, []} =
      MemoryMonitor.evaluate(state, [app(%{rss_mb: 1_023.9})], idle, later(15))

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(20))
    assert actions == [{:detected, app(), 1}]

    {state, []} =
      MemoryMonitor.evaluate(state, [app(%{cpu_percent: 1.1})], idle, later(25))

    {_state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(30))
    assert actions == [{:detected, app(), 1}]
  end

  test "a replacement PID starts a new confirmation sequence" do
    idle = 0

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {_state, actions} =
      MemoryMonitor.evaluate(state, [app(%{pid: 84})], idle, later(5))

    assert actions == [{:detected, app(%{pid: 84}), 1}]
  end

  test "never alerts for a protected app" do
    idle = 0
    protected = app(%{actionable: false})

    {_state, actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [protected], idle, @t0)

    assert actions == []
  end

  test "does not alert for the same app again during cooldown" do
    idle = 0

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(5))
    {state, [{:alert, _app}]} = MemoryMonitor.evaluate(state, [app()], idle, later(10))
    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(15))
    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(20))
    {_state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(25))

    assert actions == []
  end

  test "rapid calls and long gaps do not establish sustained memory use" do
    {state, _} = MemoryMonitor.evaluate(%{}, [app()], 0, @t0)
    {state, [{:detected, _, 1}]} = MemoryMonitor.evaluate(state, [app()], 0, @t0)
    {state, [{:detected, _, 1}]} = MemoryMonitor.evaluate(state, [app()], 0, later(11))
    {_, [{:detected, _, 1}]} = MemoryMonitor.evaluate(state, [app()], 0, @t0)
  end

  test "legacy close state does not trigger termination or bypass new confirmation" do
    legacy = %{observations: %{app().id => %{app: app(), count: 99}}, closes: %{app().id => @t0}}
    {_, [{:detected, _, 1}]} = MemoryMonitor.evaluate(legacy, [app()], 0, @t0)
  end
end
