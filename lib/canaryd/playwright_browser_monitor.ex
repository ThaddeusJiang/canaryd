defmodule Canaryd.PlaywrightBrowserMonitor do
  @moduledoc """
  Pure confirmation policy for leftover Playwright Chrome for Testing.

  A supported background browser must remain present with no Playwright runner
  for three consecutive full check rounds. Whole-Mac user idle is not required.
  """

  @required_observations 3

  def default_state do
    %{observations: %{}}
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, browsers, automation_active) do
    state = normalize_state(state)

    candidates =
      if automation_active do
        []
      else
        Enum.uniq_by(browsers, & &1.id)
      end

    active_ids = MapSet.new(candidates, & &1.id)
    state = %{state | observations: Map.take(state.observations, MapSet.to_list(active_ids))}

    Enum.reduce(candidates, {state, []}, fn browser, {current_state, actions} ->
      {next_state, action} = observe(current_state, browser)
      {next_state, [action | actions]}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  @doc "Clears incomplete observations after an unavailable or unsafe scan."
  def reset_observations(_state), do: default_state()

  def pending_browsers(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.browser)
    |> Enum.sort_by(&{&1.name, &1.pid})
  end

  def required_observations, do: @required_observations

  defp observe(state, browser) do
    previous = Map.get(state.observations, browser.id)
    previous_count = if previous, do: previous.count, else: 0
    count = previous_count + 1

    if count >= @required_observations do
      next_state = %{state | observations: Map.delete(state.observations, browser.id)}
      {next_state, {:terminate, browser}}
    else
      observation = %{browser: browser, count: count}
      next_state = %{state | observations: Map.put(state.observations, browser.id, observation)}
      {next_state, {:detected, browser, count}}
    end
  end

  defp normalize_state(state) do
    %{observations: Map.get(state, :observations, %{})}
  end
end
