defmodule Canaryd.CodexProcessMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{CodexProcessMonitor, Duration}

  defp process(overrides \\ %{}) do
    Map.merge(
      %{
        id: {:node_repl, 43, "Mon Sep 7 20:02:03 2026"},
        kind: :node_repl,
        pid: 43,
        ppid: 2072,
        started_at: "Mon Sep 7 20:02:03 2026",
        name: "node_repl"
      },
      overrides
    )
  end

  test "exposes the same conservative confirmation thresholds as Simulator monitoring" do
    assert CodexProcessMonitor.minimum_idle() == Duration.minutes(30)
    assert CodexProcessMonitor.required_observations() == 3
  end

  test "terminates after three consecutive idle observations" do
    idle = Duration.minutes(30)

    {state, actions} =
      CodexProcessMonitor.evaluate(CodexProcessMonitor.default_state(), [process()], idle)

    assert actions == [{:detected, process(), 1}]

    {state, actions} = CodexProcessMonitor.evaluate(state, [process()], idle)
    assert actions == [{:detected, process(), 2}]

    {state, actions} = CodexProcessMonitor.evaluate(state, [process()], idle)
    assert actions == [{:terminate, process()}]
    assert CodexProcessMonitor.pending_processes(state) == []
  end

  test "user activity, a missing process, and PID reuse reset confirmation" do
    idle = Duration.minutes(30)

    {state, _actions} =
      CodexProcessMonitor.evaluate(CodexProcessMonitor.default_state(), [process()], idle)

    {state, []} =
      CodexProcessMonitor.evaluate(state, [process()], Duration.minutes(29))

    {state, actions} = CodexProcessMonitor.evaluate(state, [process()], idle)
    assert actions == [{:detected, process(), 1}]

    {state, []} = CodexProcessMonitor.evaluate(state, [], idle)

    replacement =
      process(%{
        id: {:node_repl, 43, "Mon Sep 7 21:02:03 2026"},
        ppid: 9999,
        started_at: "Mon Sep 7 21:02:03 2026"
      })

    {_state, actions} = CodexProcessMonitor.evaluate(state, [replacement], idle)
    assert actions == [{:detected, replacement, 1}]
  end

  test "deduplicates identical process identities" do
    idle = Duration.minutes(30)

    {_state, actions} =
      CodexProcessMonitor.evaluate(
        CodexProcessMonitor.default_state(),
        [process(), process()],
        idle
      )

    assert actions == [{:detected, process(), 1}]
  end
end
