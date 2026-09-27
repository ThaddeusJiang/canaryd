defmodule Canaryd.BuildProcessMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{BuildProcessMonitor, Duration}

  @t0 ~U[2026-09-23 00:00:00Z]
  @process %{
    id: {"clang", 42},
    name: "clang",
    pid: 42,
    ppid: 1,
    cpu_percent: 2.0,
    rss_mb: 100.0,
    detached: true
  }

  test "alerts after three spaced observations without stopping the process" do
    {state, []} =
      BuildProcessMonitor.evaluate(BuildProcessMonitor.default_state(), [@process], @t0)

    {state, []} =
      BuildProcessMonitor.evaluate(state, [@process], Duration.add(@t0, Duration.minutes(5)))

    {_state, [{:alert, @process}]} =
      BuildProcessMonitor.evaluate(state, [@process], Duration.add(@t0, Duration.minutes(10)))
  end

  test "ignores attached build processes" do
    {_state, []} =
      BuildProcessMonitor.evaluate(
        BuildProcessMonitor.default_state(),
        [%{@process | ppid: 9, detached: false}],
        @t0
      )
  end

  test "frequent checks do not reset the confirmation window" do
    {state, []} =
      BuildProcessMonitor.evaluate(BuildProcessMonitor.default_state(), [@process], @t0)

    {state, []} =
      Enum.reduce(1..9, {state, []}, fn minute, {state, []} ->
        BuildProcessMonitor.evaluate(
          state,
          [@process],
          Duration.add(@t0, Duration.minutes(minute))
        )
      end)

    {_state, [{:alert, @process}]} =
      BuildProcessMonitor.evaluate(state, [@process], Duration.add(@t0, Duration.minutes(10)))
  end
end
