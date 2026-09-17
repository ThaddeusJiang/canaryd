defmodule Canaryd.MemoryMonitor do
  @moduledoc """
  Pure confirmation and notification cooldown for high-memory applications.

  A candidate must remain over the RSS threshold and below the CPU threshold
  for three consecutive full check rounds. Ordinary applications are only
  reported; memory use does not establish that their work can be discarded.
  """

  alias Canaryd.Duration

  @memory_threshold_mb 1_024.0
  @cpu_threshold 1.0
  @minimum_spacing Duration.minutes(5)
  @maximum_gap Duration.minutes(10)
  @required_observations 3
  @alert_cooldown Duration.hours(1)

  def default_state do
    %{
      observations: %{},
      alerts: %{}
    }
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, apps, _idle_duration, now) do
    state = normalize_state(state, now)

    candidates = apps |> Enum.filter(&candidate?/1) |> Enum.uniq_by(& &1.id)

    active_ids = MapSet.new(candidates, & &1.id)
    state = %{state | observations: Map.take(state.observations, MapSet.to_list(active_ids))}

    Enum.reduce(candidates, {state, []}, fn app, {current_state, actions} ->
      {next_state, action} = observe(current_state, app, now)
      next_actions = if is_nil(action), do: actions, else: [action | actions]
      {next_state, next_actions}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  @doc "Clears incomplete observations after an unavailable process scan."
  def reset_observations(state) do
    %{
      observations: %{},
      alerts: Map.get(state, :alerts, %{})
    }
  end

  def pending_apps(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.app)
    |> Enum.sort_by(& &1.rss_mb, :desc)
  end

  def candidate?(app) do
    app.actionable and app.rss_mb >= @memory_threshold_mb and
      app.cpu_percent <= @cpu_threshold
  end

  def memory_threshold_mb, do: @memory_threshold_mb
  def cpu_threshold, do: @cpu_threshold
  def required_observations, do: @required_observations
  def alert_cooldown, do: @alert_cooldown

  defp observe(state, app, now) do
    previous = Map.get(state.observations, app.id)

    {count, counted_at} =
      case previous do
        %{app: %{pid: pid}, count: count, last_seen: last_seen, counted_at: counted_at}
        when pid == app.pid ->
          gap = Duration.between(now, last_seen)

          cond do
            gap < 0 or gap > @maximum_gap -> {1, now}
            Duration.between(now, counted_at) >= @minimum_spacing -> {count + 1, now}
            true -> {count, counted_at}
          end

        _ ->
          {1, now}
      end

    if count >= @required_observations and alert_allowed?(state, app.id, now) do
      next_state = %{
        state
        | observations: Map.delete(state.observations, app.id),
          alerts: Map.put(state.alerts, app.id, now)
      }

      {next_state, {:alert, app}}
    else
      observation = %{app: app, count: count, last_seen: now, counted_at: counted_at}
      next_state = %{state | observations: Map.put(state.observations, app.id, observation)}
      action = if count < @required_observations, do: {:detected, app, count}, else: nil
      {next_state, action}
    end
  end

  defp alert_allowed?(state, id, now) do
    case Map.get(state.alerts, id) do
      nil -> true
      last_alert -> Duration.between(now, last_alert) >= @alert_cooldown
    end
  end

  defp normalize_state(state, now) do
    alerts = Map.get(state, :alerts, %{})

    recent_alerts =
      Map.filter(alerts, fn {_id, alerted_at} ->
        Duration.between(now, alerted_at) < Duration.days(1)
      end)

    %{
      observations: Map.get(state, :observations, %{}),
      alerts: recent_alerts
    }
  end
end
