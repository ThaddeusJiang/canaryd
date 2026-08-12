defmodule Canaryd.MemoryMonitor do
  @moduledoc """
  Pure confirmation and cooldown policy for idle, high-memory applications.

  A candidate must remain over the RSS threshold and below the CPU threshold
  while the user is idle for three consecutive full check rounds. Only
  applications marked actionable by `Canaryd.MemoryProcesses` can be closed.
  """

  alias Canaryd.Duration

  @memory_threshold_mb 1_024.0
  @cpu_threshold 1.0
  @minimum_idle Duration.minutes(30)
  @required_observations 3
  @close_cooldown Duration.hours(1)

  def default_state do
    %{
      observations: %{},
      closes: %{}
    }
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, apps, idle_duration, now) do
    state = normalize_state(state, now)

    candidates =
      if idle_duration >= @minimum_idle do
        apps
        |> Enum.filter(&candidate?/1)
        |> Enum.uniq_by(& &1.id)
      else
        []
      end

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
      closes: Map.get(state, :closes, %{})
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

  def minimum_idle, do: @minimum_idle
  def memory_threshold_mb, do: @memory_threshold_mb
  def cpu_threshold, do: @cpu_threshold
  def required_observations, do: @required_observations
  def close_cooldown, do: @close_cooldown

  defp observe(state, app, now) do
    previous = Map.get(state.observations, app.id)
    previous_count = if previous && previous.app.pid == app.pid, do: previous.count, else: 0
    count = previous_count + 1

    if count >= @required_observations and close_allowed?(state, app.id, now) do
      next_state = %{
        state
        | observations: Map.delete(state.observations, app.id),
          closes: Map.put(state.closes, app.id, now)
      }

      {next_state, {:close, app}}
    else
      observation = %{app: app, count: count}
      next_state = %{state | observations: Map.put(state.observations, app.id, observation)}
      action = if count < @required_observations, do: {:detected, app, count}, else: nil
      {next_state, action}
    end
  end

  defp close_allowed?(state, id, now) do
    case Map.get(state.closes, id) do
      nil -> true
      last_close -> Duration.between(now, last_close) >= @close_cooldown
    end
  end

  defp normalize_state(state, now) do
    closes = Map.get(state, :closes, %{})

    recent_closes =
      Map.filter(closes, fn {_id, closed_at} ->
        Duration.between(now, closed_at) < Duration.days(1)
      end)

    %{
      observations: Map.get(state, :observations, %{}),
      closes: recent_closes
    }
  end
end
