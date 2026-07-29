defmodule Canaryd.UnresponsiveMonitor do
  @moduledoc """
  Pure confirmation and cooldown policy for unresponsive GUI apps.
  """

  @confirmation_count 2
  @restart_cooldown 3_600
  @restart_retention 86_400
  @prompt_cooldown 3_600
  @prompt_retention 86_400

  def default_state do
    %{
      observations: %{},
      restarts: %{},
      prompts: %{},
      blocked: MapSet.new()
    }
  end

  @doc """
  Evaluates one scan and returns `{new_state, actions}`.

  Actions are `{:detected, app, count}`, `{:restart, app}`, `{:choose, app}`,
  or `{:blocked, app}`.
  """
  def evaluate(state, apps, now) do
    state = normalize_state(state, now)
    apps = Enum.uniq_by(apps, & &1.id)
    active_ids = MapSet.new(apps, & &1.id)

    state = %{
      state
      | observations: Map.take(state.observations, MapSet.to_list(active_ids)),
        blocked: MapSet.intersection(state.blocked, active_ids)
    }

    Enum.reduce(apps, {state, []}, fn app, {current_state, actions} ->
      {next_state, action} = observe(current_state, app, now)
      next_actions = if is_nil(action), do: actions, else: [action | actions]
      {next_state, next_actions}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  def pending_apps(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.app)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Breaks the consecutive observation sequence after an unavailable scan."
  def reset_observations(state) do
    %{
      observations: %{},
      restarts: Map.get(state, :restarts, %{}),
      prompts: Map.get(state, :prompts, %{}),
      blocked: Map.get(state, :blocked, MapSet.new())
    }
  end

  @doc "Restart cooldown in seconds."
  def restart_cooldown, do: @restart_cooldown

  defp observe(state, app, now) do
    previous_count = get_in(state, [:observations, app.id, :count]) || 0
    count = previous_count + 1

    cond do
      count < @confirmation_count ->
        observation = %{app: app, count: count}

        {%{state | observations: Map.put(state.observations, app.id, observation)},
         {:detected, app, count}}

      app.recovery == :interactive and prompt_allowed?(state, app.id, now) ->
        next_state = %{
          state
          | observations: Map.delete(state.observations, app.id),
            prompts: Map.put(state.prompts, app.id, now)
        }

        {next_state, {:choose, app}}

      app.recovery == :interactive ->
        observation = %{app: app, count: count}
        {%{state | observations: Map.put(state.observations, app.id, observation)}, nil}

      restart_allowed?(state, app.id, now) ->
        next_state = %{
          state
          | observations: Map.delete(state.observations, app.id),
            restarts: Map.put(state.restarts, app.id, now),
            blocked: MapSet.delete(state.blocked, app.id)
        }

        {next_state, {:restart, app}}

      MapSet.member?(state.blocked, app.id) ->
        observation = %{app: app, count: count}
        {%{state | observations: Map.put(state.observations, app.id, observation)}, nil}

      true ->
        observation = %{app: app, count: count}

        next_state = %{
          state
          | observations: Map.put(state.observations, app.id, observation),
            blocked: MapSet.put(state.blocked, app.id)
        }

        {next_state, {:blocked, app}}
    end
  end

  defp restart_allowed?(state, id, now) do
    case Map.get(state.restarts, id) do
      nil -> true
      last_restart -> DateTime.diff(now, last_restart, :second) >= @restart_cooldown
    end
  end

  defp prompt_allowed?(state, id, now) do
    case Map.get(state.prompts, id) do
      nil -> true
      last_prompt -> DateTime.diff(now, last_prompt, :second) >= @prompt_cooldown
    end
  end

  defp normalize_state(state, now) do
    defaults = default_state()
    restarts = Map.get(state, :restarts, defaults.restarts)
    prompts = Map.get(state, :prompts, defaults.prompts)

    recent_restarts =
      Map.filter(restarts, fn {_id, restarted_at} ->
        DateTime.diff(now, restarted_at, :second) < @restart_retention
      end)

    recent_prompts =
      Map.filter(prompts, fn {_id, prompted_at} ->
        DateTime.diff(now, prompted_at, :second) < @prompt_retention
      end)

    %{
      observations: Map.get(state, :observations, defaults.observations),
      restarts: recent_restarts,
      prompts: recent_prompts,
      blocked: Map.get(state, :blocked, defaults.blocked)
    }
  end
end
