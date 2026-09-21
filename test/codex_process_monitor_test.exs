defmodule Canaryd.CodexProcessMonitorTest do
  use ExUnit.Case, async: true
  alias Canaryd.{CodexProcessMonitor, Duration}

  defp process(overrides \\ %{}) do
    Map.merge(
      %{
        id: {:node_repl, 43, "start"},
        kind: :node_repl,
        pid: 43,
        ppid: 2072,
        name: "node_repl",
        cpu_time: 130,
        protection: nil
      },
      overrides
    )
  end

  defp evaluate(state, processes, minute, idle \\ 0),
    do: CodexProcessMonitor.evaluate(state, processes, idle, Duration.minutes(minute))

  test "reports a quiet empty REPL after 30 minutes even while the user works" do
    state =
      Enum.reduce(0..5, CodexProcessMonitor.default_state(), fn n, state ->
        {state, [{:detected, _, _}]} = evaluate(state, [process()], n * 5)
        state
      end)

    assert {state, [{:quiet, target}]} = evaluate(state, [process()], 30)
    assert target == process()
    assert CodexProcessMonitor.pending_processes(state) == []
  end

  test "CPU activity resets the full observation window" do
    {state, _} = evaluate(%{}, [process()], 0)
    {state, _} = evaluate(state, [process()], 10)
    changed = process(%{cpu_time: 140})
    {state, [{:detected, ^changed, 1}]} = evaluate(state, [changed], 20)
    {_, [{:detected, ^changed, 2}]} = evaluate(state, [changed], 30)
  end

  test "working children are protected even when the Mac is idle" do
    target = process(%{protection: :working_children})
    assert {state, []} = evaluate(%{}, [target], 0, Duration.hours(2))
    assert state.observations == %{}
  end

  test "MCP adapters have unknown session activity even with an idle Mac or parent PID 1" do
    adapter = process(%{kind: :cua_driver_mcp})
    assert {_, []} = evaluate(%{}, [adapter], 0)
    assert {_, []} = evaluate(%{}, [adapter], 0, Duration.minutes(30))
    orphan = %{adapter | ppid: 1}
    assert {_, []} = evaluate(%{}, [orphan], 0)
  end

  test "rapid invocations cannot advance confirmation or bypass elapsed time" do
    state =
      Enum.reduce(1..20, %{}, fn _, state ->
        {state, [{:detected, _, 1}]} = evaluate(state, [process()], 0)
        state
      end)

    {_, [{:detected, _, 1}]} = evaluate(state, [process()], 1)
  end

  test "missing scans, sleep gaps, backwards clocks and changed parent reset history" do
    for {minute, processes} <- [{11, [process()]}, {-1, [process()]}, {5, [process(%{ppid: 99})]}] do
      {state, _} = evaluate(%{}, [process()], 0)
      assert {_, [{:detected, _, 1}]} = evaluate(state, processes, minute)
    end

    {state, _} = evaluate(%{}, [process()], 0)
    assert {state, []} = evaluate(state, [], 5)
    assert state.observations == %{}
    assert CodexProcessMonitor.reset_observations(state) == CodexProcessMonitor.default_state()
  end

  test "legacy observations and PID reuse start a fresh window" do
    legacy = %{observations: %{process().id => %{process: process(), count: 99}}}
    assert {_, [{:detected, _, 1}]} = evaluate(legacy, [process()], 0)
    {state, _} = evaluate(%{}, [process()], 0)
    replacement = process(%{id: {:node_repl, 43, "new start"}})
    assert {_, [{:detected, ^replacement, 1}]} = evaluate(state, [replacement], 5)
  end

  test "deduplicates identical processes and fails closed without activity metadata" do
    assert {_, [{:detected, _, 1}]} = evaluate(%{}, [process(), process()], 0)
    assert {_, []} = evaluate(%{}, [Map.delete(process(), :cpu_time)], 0)
  end
end
