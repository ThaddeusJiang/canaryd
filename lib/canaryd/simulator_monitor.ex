defmodule Canaryd.SimulatorMonitor do
  @moduledoc """
  Pure confirmation policy for shutting down idle booted Simulator devices.

  A device must be old enough, the user must be away, and no supported test
  automation can be active for three consecutive full check rounds.
  """

  alias Canaryd.Duration

  @minimum_idle Duration.minutes(30)
  @required_observations 3

  def default_state do
    %{observations: %{}}
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, devices, idle_duration, automation_active, now) do
    state = normalize_state(state)

    candidates =
      if idle_duration >= @minimum_idle and not automation_active do
        devices
        |> Enum.filter(&candidate?(&1, now))
        |> Enum.uniq_by(& &1.udid)
      else
        []
      end

    active_ids = MapSet.new(candidates, & &1.udid)
    state = %{state | observations: Map.take(state.observations, MapSet.to_list(active_ids))}

    Enum.reduce(candidates, {state, []}, fn device, {current_state, actions} ->
      {next_state, action} = observe(current_state, device)
      {next_state, [action | actions]}
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  @doc "Clears incomplete observations after an unavailable or unsafe scan."
  def reset_observations(_state), do: default_state()

  def pending_devices(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.device)
    |> Enum.sort_by(& &1.name)
  end

  def candidate?(%{state: :booted, last_used_at: %DateTime{} = last_used_at}, now) do
    Duration.between(now, last_used_at) >= @minimum_idle
  end

  def candidate?(_device, _now), do: false

  def minimum_idle, do: @minimum_idle
  def required_observations, do: @required_observations

  defp observe(state, device) do
    previous = Map.get(state.observations, device.udid)

    previous_count =
      if previous && same_device_session?(previous.device, device), do: previous.count, else: 0

    count = previous_count + 1

    if count >= @required_observations do
      next_state = %{state | observations: Map.delete(state.observations, device.udid)}
      {next_state, {:shutdown, device}}
    else
      observation = %{device: device, count: count}
      next_state = %{state | observations: Map.put(state.observations, device.udid, observation)}
      {next_state, {:detected, device, count}}
    end
  end

  defp same_device_session?(previous, current) do
    previous.udid == current.udid and previous.last_used_at == current.last_used_at
  end

  defp normalize_state(state) do
    %{observations: Map.get(state, :observations, %{})}
  end
end
