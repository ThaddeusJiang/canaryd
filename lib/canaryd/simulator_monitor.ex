defmodule Canaryd.SimulatorMonitor do
  @moduledoc """
  Fixed inactivity policy for shutting down idle booted Simulator devices.

  A device becomes actionable 15 minutes after its latest known activity.
  Simulator foreground use and supported test automation block shutdown.
  """

  alias Canaryd.Duration

  @minimum_idle Duration.minutes(15)

  def default_state do
    %{observations: %{}, last_foreground_at: nil}
  end

  @doc "Evaluates one scan and returns `{new_state, actions}`."
  def evaluate(state, devices, simulator_foreground, automation_active, now) do
    state = state |> normalize_state() |> record_foreground(simulator_foreground, now)

    candidates =
      if not simulator_foreground and not automation_active do
        devices
        |> Enum.filter(&candidate?(&1, state.last_foreground_at, now))
        |> Enum.uniq_by(& &1.udid)
      else
        []
      end

    state = %{state | observations: %{}}
    {state, Enum.map(candidates, &{:shutdown, &1})}
  end

  @doc "Clears incomplete observations after an unavailable or unsafe scan."
  def reset_observations(state) do
    state = normalize_state(state)
    %{state | observations: %{}}
  end

  def pending_devices(state) do
    state
    |> Map.get(:observations, %{})
    |> Map.values()
    |> Enum.map(& &1.device)
    |> Enum.sort_by(& &1.name)
  end

  def candidate?(device, now), do: candidate?(device, nil, now)

  def candidate?(
        %{state: :booted, last_used_at: %DateTime{} = last_used_at},
        last_foreground_at,
        now
      ) do
    last_activity_at = latest_activity(last_used_at, last_foreground_at)
    Duration.between(now, last_activity_at) >= @minimum_idle
  end

  def candidate?(_device, _last_foreground_at, _now), do: false

  def minimum_idle, do: @minimum_idle

  defp normalize_state(state) do
    %{
      observations: Map.get(state, :observations, %{}),
      last_foreground_at: Map.get(state, :last_foreground_at)
    }
  end

  defp record_foreground(state, true, now), do: %{state | last_foreground_at: now}
  defp record_foreground(state, false, _now), do: state

  defp latest_activity(last_used_at, %DateTime{} = last_foreground_at) do
    case DateTime.compare(last_used_at, last_foreground_at) do
      :lt -> last_foreground_at
      _ -> last_used_at
    end
  end

  defp latest_activity(last_used_at, _last_foreground_at), do: last_used_at
end
