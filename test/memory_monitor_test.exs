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
    assert MemoryMonitor.minimum_idle() == 1_800_000
    assert MemoryMonitor.memory_threshold_mb() == 1_024.0
    assert MemoryMonitor.cpu_threshold() == 1.0
    assert MemoryMonitor.required_observations() == 3
    assert MemoryMonitor.close_cooldown() == 3_600_000
  end

  test "closes after three consecutive idle high-memory observations" do
    idle = Duration.minutes(30)

    {state, actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    assert actions == [{:detected, app(), 1}]

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(5))
    assert actions == [{:detected, app(), 2}]

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(10))
    assert actions == [{:close, app()}]
    assert MemoryMonitor.pending_apps(state) == []
  end

  test "active user, lower memory, and CPU activity reset confirmation" do
    idle = Duration.minutes(30)

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {state, []} =
      MemoryMonitor.evaluate(state, [app()], Duration.minutes(29), later(5))

    {state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(10))
    assert actions == [{:detected, app(), 1}]

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
    idle = Duration.minutes(30)

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {_state, actions} =
      MemoryMonitor.evaluate(state, [app(%{pid: 84})], idle, later(5))

    assert actions == [{:detected, app(%{pid: 84}), 1}]
  end

  test "never closes a protected app" do
    idle = Duration.minutes(30)
    protected = app(%{actionable: false})

    {_state, actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [protected], idle, @t0)

    assert actions == []
  end

  test "does not close the same app again during cooldown" do
    idle = Duration.minutes(30)

    {state, _actions} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app()], idle, @t0)

    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(5))
    {state, [{:close, _app}]} = MemoryMonitor.evaluate(state, [app()], idle, later(10))
    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(15))
    {state, _actions} = MemoryMonitor.evaluate(state, [app()], idle, later(20))
    {_state, actions} = MemoryMonitor.evaluate(state, [app()], idle, later(25))

    assert actions == []
  end
end
