defmodule Canaryd.BuildProcessMonitor do
  @moduledoc """
  Confirms detached build processes and reports them without stopping them.
  """

  alias Canaryd.{Duration, PolicyConfig}

  def default_state, do: %{observations: %{}, alerts: %{}}

  def evaluate(state, processes, now, policy \\ PolicyConfig.defaults()) do
    state = normalize_state(state, now)
    candidates = Enum.filter(processes, & &1.detached)
    active_ids = MapSet.new(candidates, & &1.id)
    state = %{state | observations: Map.take(state.observations, MapSet.to_list(active_ids))}

    Enum.reduce(candidates, {state, []}, fn process, {current, actions} ->
      {next, action} = observe(current, process, now, policy)
      {next, if(action, do: [action | actions], else: actions)}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  defp observe(state, process, now, policy) do
    previous = Map.get(state.observations, process.id)

    observation =
      case previous do
        %{process: %{pid: pid}, count: count, last_seen: last_seen} when pid == process.pid ->
          gap = Duration.between(now, last_seen)
          counted_at = Map.get(previous, :counted_at, last_seen)
          spaced = Duration.between(now, counted_at) >= policy.build_process_min_spacing

          if gap >= 0 and gap <= policy.build_process_max_gap do
            %{
              process: process,
              count: count + if(spaced, do: 1, else: 0),
              last_seen: now,
              counted_at: if(spaced, do: now, else: counted_at)
            }
          else
            %{process: process, count: 1, last_seen: now, counted_at: now}
          end

        _ ->
          %{process: process, count: 1, last_seen: now, counted_at: now}
      end

    if observation.count >= policy.build_process_confirmations and
         alert_allowed?(state, process.id, now, policy) do
      next_state = %{
        state
        | observations: Map.delete(state.observations, process.id),
          alerts: Map.put(state.alerts, process.id, now)
      }

      {next_state, {:alert, process}}
    else
      {%{state | observations: Map.put(state.observations, process.id, observation)}, nil}
    end
  end

  defp alert_allowed?(state, id, now, policy) do
    case Map.get(state.alerts, id) do
      nil -> true
      last_alert -> Duration.between(now, last_alert) >= policy.build_process_alert_cooldown
    end
  end

  defp normalize_state(state, now) do
    alerts =
      state
      |> Map.get(:alerts, %{})
      |> Map.filter(fn {_id, at} -> Duration.between(now, at) < Duration.days(1) end)

    %{observations: Map.get(state, :observations, %{}), alerts: alerts}
  end
end
