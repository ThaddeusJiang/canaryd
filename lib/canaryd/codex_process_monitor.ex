defmodule Canaryd.CodexProcessMonitor do
  @moduledoc """
  Pure confirmation policy for idle Codex screen-control helpers.

  A supported process must remain present while the user is away for three
  consecutive full check rounds before Canaryd requests termination.
  """

  alias Canaryd.Duration

  @minimum_idle Duration.minutes(30)
  @required_observations 3

  def default_state do
    %{observations: %{}}
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, processes, idle_duration) do
    state = normalize_state(state)

    candidates =
      if idle_duration >= @minimum_idle do
        Enum.uniq_by(processes, & &1.id)
      else
        []
      end

    active_ids = MapSet.new(candidates, & &1.id)
    state = %{state | observations: Map.take(state.observations, MapSet.to_list(active_ids))}

    Enum.reduce(candidates, {state, []}, fn process, {current_state, actions} ->
      {next_state, action} = observe(current_state, process)
      {next_state, [action | actions]}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  @doc "Clears incomplete observations after an unavailable process scan."
  def reset_observations(_state), do: default_state()

  def pending_processes(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.process)
    |> Enum.sort_by(&{&1.name, &1.pid})
  end

  def minimum_idle, do: @minimum_idle
  def required_observations, do: @required_observations

  defp observe(state, process) do
    previous = Map.get(state.observations, process.id)
    previous_count = if previous, do: previous.count, else: 0
    count = previous_count + 1

    if count >= @required_observations do
      next_state = %{state | observations: Map.delete(state.observations, process.id)}
      {next_state, {:terminate, process}}
    else
      observation = %{process: process, count: count}
      next_state = %{state | observations: Map.put(state.observations, process.id, observation)}
      {next_state, {:detected, process, count}}
    end
  end

  defp normalize_state(state) do
    %{observations: Map.get(state, :observations, %{})}
  end
end
