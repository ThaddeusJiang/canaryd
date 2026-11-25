defmodule Canaryd.DiskPressureMonitor do
  @moduledoc """
  Hysteresis and cooldown for threshold-triggered cleanup.
  """

  alias Canaryd.{Disk, DiskPressureConfig, Duration, PolicyConfig}

  def default_state do
    %{active: false, last_triggered_at: nil, last_emergency_triggered_at: nil}
  end

  @doc "Returns `{state, actions}`; actions are guarded cleanup requests."
  def evaluate(
        state,
        usage,
        now,
        threshold_bytes \\ DiskPressureConfig.default_bytes(),
        policy \\ PolicyConfig.defaults()
      ) do
    state = normalize_state(state)

    cond do
      not is_map(usage) ->
        {state, []}

      emergency?(usage, policy) and emergency_allowed?(state, now, policy) ->
        {%{state | active: true, last_triggered_at: now, last_emergency_triggered_at: now},
         [{:emergency_cleanup, usage}]}

      emergency?(usage, policy) ->
        {state, []}

      state.active and recovered?(usage, threshold_bytes) ->
        {%{state | active: false}, []}

      Disk.pressure?(usage, threshold_bytes) and trigger_allowed?(state, now, policy) ->
        {%{state | active: true, last_triggered_at: now}, [{:cleanup, usage}]}

      true ->
        {state, []}
    end
  end

  defp recovered?(%{available_bytes: available_bytes}, threshold_bytes) do
    available_bytes >= threshold_bytes
  end

  defp recovered?(_usage, _threshold_bytes), do: false

  defp trigger_allowed?(%{last_triggered_at: nil}, _now, _policy), do: true

  defp trigger_allowed?(%{last_triggered_at: last_triggered_at}, now, policy) do
    Duration.between(now, last_triggered_at) >= policy.storage_cleanup_cooldown
  end

  defp emergency?(%{available_bytes: available_bytes}, policy)
       when is_integer(available_bytes) and available_bytes >= 0,
       do: available_bytes < policy.storage_emergency_threshold * 1_024 * 1_024

  defp emergency?(_usage, _policy), do: false

  defp emergency_allowed?(%{last_emergency_triggered_at: nil}, _now, _policy), do: true

  defp emergency_allowed?(%{last_emergency_triggered_at: last}, now, policy) do
    Duration.between(now, last) >= Duration.minutes(policy.check_interval)
  end

  defp normalize_state(state) do
    %{
      active: Map.get(state, :active, false),
      last_triggered_at: Map.get(state, :last_triggered_at),
      last_emergency_triggered_at: Map.get(state, :last_emergency_triggered_at)
    }
  end
end
