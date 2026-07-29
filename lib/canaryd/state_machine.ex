defmodule Canaryd.StateMachine do
  @moduledoc """
  Pure transition logic for per-target health. Testable without side effects.

  State: %{last_probe, consecutive_failures, last_restart_at, status, updated_at}

  Rules (high threshold, restart silently, only bother the user when blocked):
    * probe ok after trouble        -> :recovered, reset counters
    * probe fail, restart allowed   -> :restart (cooldown: 1h between restarts)
    * probe fail, restart on cooldown, failures < 3 -> :wait (log only)
    * probe fail, restart on cooldown, failures >= 3 -> :blocked (notify once)
  """

  alias Canaryd.Duration

  @restart_cooldown Duration.hours(1)
  @block_threshold 3

  def transition(state, :ok, now) do
    action =
      if state.consecutive_failures > 0 or state.status == :blocked, do: :recovered, else: :none

    new = %{
      state
      | last_probe: :ok,
        consecutive_failures: 0,
        status: :ok,
        updated_at: now
    }

    {new, action}
  end

  def transition(state, :fail, now) do
    failures = state.consecutive_failures + 1
    cooldown_over = restart_allowed?(state.last_restart_at, now)

    cond do
      state.status == :blocked and not cooldown_over ->
        {%{state | last_probe: :fail, consecutive_failures: failures, updated_at: now}, :wait}

      cooldown_over and state.status != :blocked ->
        {%{
           state
           | last_probe: :fail,
             consecutive_failures: failures,
             last_restart_at: now,
             updated_at: now
         }, :restart}

      failures >= @block_threshold ->
        {%{
           state
           | last_probe: :fail,
             consecutive_failures: failures,
             status: :blocked,
             updated_at: now
         }, :blocked}

      true ->
        {%{state | last_probe: :fail, consecutive_failures: failures, updated_at: now}, :wait}
    end
  end

  defp restart_allowed?(nil, _now), do: true

  defp restart_allowed?(last, now) do
    Duration.between(now, last) >= @restart_cooldown
  end

  @doc "Restart cooldown in milliseconds."
  def restart_cooldown, do: @restart_cooldown
end
