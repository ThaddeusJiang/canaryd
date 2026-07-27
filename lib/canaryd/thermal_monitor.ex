defmodule Canaryd.ThermalMonitor do
  @moduledoc """
  Confirms sustained thermal pressure and limits user action prompts.

  Process CPU usage is correlation evidence. It is not exact power attribution.
  """

  @confirmation_count 2
  @prompt_cooldown_sec 3_600
  @retention_sec 86_400

  def default_state do
    %{observations: %{}, prompts: %{}}
  end

  @doc """
  Evaluates one thermal sample and returns `{new_state, actions}`.

  Actions are `{:detected, process, suspects}`, `{:choose, process, suspects}`,
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

      state.observations == %{} ->
        observation = %{reported: %{at: now}}
        {%{state | observations: observation}, [{:report, suspects}]}

      true ->
        {state, []}
    end
  end

  defp observe_actionable(state, process, suspects, now) do
    if prompt_allowed?(state, process.id, now) do
      previous_count = get_in(state, [:observations, process.id, :count]) || 0
      count = previous_count + 1

      if count < @confirmation_count do
        observation = %{process: process, count: count}

        {%{state | observations: %{process.id => observation}}, [{:detected, process, suspects}]}
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

  defp prompt_allowed?(state, id, now) do
    case Map.get(state.prompts, id) do
      nil -> true
      prompted_at -> DateTime.diff(now, prompted_at, :second) >= @prompt_cooldown_sec
    end
  end

  defp normalize_state(state, now) do
    prompts =
      state
      |> Map.get(:prompts, %{})
      |> Map.filter(fn {_id, prompted_at} ->
        DateTime.diff(now, prompted_at, :second) < @retention_sec
      end)

    %{
      observations: Map.get(state, :observations, %{}),
      prompts: prompts
    }
  end
end
