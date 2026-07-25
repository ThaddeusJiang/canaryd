defmodule Canaryd.StateMachineTest do
  use ExUnit.Case, async: true

  alias Canaryd.{StateMachine, Store}

  @t0 ~U[2026-07-26 00:00:00Z]

  defp fresh, do: Store.default_state()

  test "ok probe keeps status ok with no action" do
    {state, action} = StateMachine.transition(fresh(), :ok, @t0)
    assert action == :none
    assert state.status == :ok
    assert state.consecutive_failures == 0
  end

  test "first failure triggers silent restart" do
    {state, action} = StateMachine.transition(fresh(), :fail, @t0)
    assert action == :restart
    assert state.consecutive_failures == 1
    assert state.last_restart_at == @t0
    assert state.status == :ok
  end

  test "failure during restart cooldown waits silently" do
    {state, :restart} = StateMachine.transition(fresh(), :fail, @t0)
    {state2, action} = StateMachine.transition(state, :fail, DateTime.add(@t0, 300, :second))
    assert action == :wait
    assert state2.consecutive_failures == 2
    assert state2.status == :ok
  end

  test "repeated failures during cooldown eventually block and notify" do
    {s1, :restart} = StateMachine.transition(fresh(), :fail, @t0)
    {s2, :wait} = StateMachine.transition(s1, :fail, DateTime.add(@t0, 300, :second))
    {s3, action} = StateMachine.transition(s2, :fail, DateTime.add(@t0, 600, :second))
    assert action == :blocked
    assert s3.status == :blocked
  end

  test "restart is allowed again after cooldown expires" do
    {s1, :restart} = StateMachine.transition(fresh(), :fail, @t0)
    later = DateTime.add(@t0, 3_601, :second)
    {s2, action} = StateMachine.transition(s1, :fail, later)
    assert action == :restart
    assert s2.last_restart_at == later
  end

  test "ok probe after failures recovers and resets" do
    {s1, :restart} = StateMachine.transition(fresh(), :fail, @t0)
    {s2, action} = StateMachine.transition(s1, :ok, DateTime.add(@t0, 300, :second))
    assert action == :recovered
    assert s2.status == :ok
    assert s2.consecutive_failures == 0
  end

  test "blocked state recovers on ok probe" do
    blocked = %{fresh() | status: :blocked, consecutive_failures: 5, last_restart_at: @t0}
    {state, action} = StateMachine.transition(blocked, :ok, DateTime.add(@t0, 100, :second))
    assert action == :recovered
    assert state.status == :ok
  end
end
