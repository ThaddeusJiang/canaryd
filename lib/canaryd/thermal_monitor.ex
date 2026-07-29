defmodule Canaryd.ThermalMonitor do
  @moduledoc """
  Confirms sustained thermal pressure and limits user action prompts.

  Process CPU usage is correlation evidence. It is not exact power attribution.
  """

  alias Canaryd.Duration

  def default_state do
    %{observations: %{}, alerts: %{}, prompts: %{}}
  end

  @doc """
  Evaluates one thermal sample and returns `{new_state, actions}`.

  Actions are `{:alert, process, suspects}`, `{:choose, process, suspects}`,
  or `{:report, suspects}`.
  """
  def evaluate(state, thermal_pressure, suspects, now) do
    state = normalize_state(state, now)
    suspects = Enum.take(suspects, 5)

    cond do
      not thermal_pressure or suspects == [] ->
        {%{state | observations: %{}}, []}

      actionable = Enum.find(suspects, & &1.actionable) ->
        observe_actionable(state, actionable, suspects, now)

      true ->
        report_protected(state, suspects, now)
    end
  end

  defp observe_actionable(state, process, suspects, now) do
    if prompt_allowed?(state, process.id, now) do
      previous_count = get_in(state, [:observations, process.id, :count]) || 0
      count = previous_count + 1

      if count < 2 do
        observation = %{process: process, count: count}
        next_state = %{state | observations: %{process.id => observation}}

        if alert_allowed?(state, process.id, now) do
          next_state = %{next_state | alerts: Map.put(state.alerts, process.id, now)}
          {next_state, [{:alert, process, suspects}]}
        else
          {next_state, []}
        end
      else
        next_state = %{
          state
          | observations: %{},
            prompts: Map.put(state.prompts, process.id, now)
        }

        {next_state, [{:choose, process, suspects}]}
      end
    else
      {%{state | observations: %{}}, []}
    end
  end

  defp report_protected(state, suspects, now) do
    process = hd(suspects)
    next_state = %{state | observations: %{reported: %{at: now}}}

    if alert_allowed?(state, process.id, now) do
      next_state = %{next_state | alerts: Map.put(state.alerts, process.id, now)}
      {next_state, [{:report, suspects}]}
    else
      {next_state, []}
    end
  end

  defp alert_allowed?(state, id, now) do
    case Map.get(state.alerts, id) do
      nil -> true
      alerted_at -> Duration.between(now, alerted_at) >= Duration.minutes(15)
    end
  end

  defp prompt_allowed?(state, id, now) do
    case Map.get(state.prompts, id) do
      nil -> true
      prompted_at -> Duration.between(now, prompted_at) >= Duration.hours(1)
    end
  end

  defp normalize_state(state, now) do
    alerts = recent_entries(Map.get(state, :alerts, %{}), now)
    prompts = recent_entries(Map.get(state, :prompts, %{}), now)

    %{
      observations: Map.get(state, :observations, %{}),
      alerts: alerts,
      prompts: prompts
    }
  end

  defp recent_entries(entries, now) do
    Map.filter(entries, fn {_id, recorded_at} ->
      Duration.between(now, recorded_at) < Duration.days(1)
    end)
  end
end
