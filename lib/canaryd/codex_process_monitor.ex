defmodule Canaryd.CodexProcessMonitor do
  @moduledoc """
  Confirms quiet, childless Codex helpers over a real observation window.

  Empty REPL and CUA hosts do not require whole-Mac inactivity.
  Initialized execution kernels are protected by the process scanner.
  """

  alias Canaryd.Duration

  @minimum_idle Duration.minutes(30)
  @minimum_spacing Duration.minutes(5)
  @maximum_gap Duration.minutes(10)
  @required_observations 3

  def default_state, do: %{observations: %{}}

  @doc "Evaluates one scan; timestamps are Unix milliseconds across CLI invocations."
  def evaluate(state, processes, idle_duration, now \\ System.system_time(:millisecond)) do
    candidates = processes |> Enum.uniq_by(& &1.id) |> Enum.filter(&eligible?(&1, idle_duration))
    previous = Map.get(state, :observations, %{})

    Enum.reduce(candidates, {default_state(), []}, fn process, {next_state, actions} ->
      observation = observe(Map.get(previous, process.id), process, now)

      if observation.count >= @required_observations and
           now - observation.quiet_since >= @minimum_idle do
        {next_state, [{:terminate, process} | actions]}
      else
        next_state = put_in(next_state, [:observations, process.id], observation)
        {next_state, [{:detected, process, observation.count} | actions]}
      end
    end)
    |> then(fn {new_state, actions} -> {new_state, Enum.reverse(actions)} end)
  end

  @doc "Returns why a process must be kept, or nil when it may be observed."
  def protection_reason(process, idle_duration) do
    cond do
      not is_integer(Map.get(process, :cpu_time)) ->
        :activity_unavailable

      Map.get(process, :protection, :activity_unavailable) != nil ->
        process[:protection] || :activity_unavailable

      process.kind in [:node_repl, :computer_use_launcher] ->
        nil

      idle_duration < @minimum_idle ->
        :user_active

      true ->
        nil
    end
  end

  def eligible?(process, idle_duration), do: is_nil(protection_reason(process, idle_duration))

  @doc "Clears incomplete observations after an unavailable scan."
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

  defp observe(previous, process, now) do
    case previous do
      %{process: old, last_seen: last_seen, counted_at: counted_at} = observation
      when now >= last_seen and now - last_seen <= @maximum_gap ->
        if Map.take(old, [:id, :ppid, :cpu_time]) ==
             Map.take(process, [:id, :ppid, :cpu_time]) do
          spaced = now - counted_at >= @minimum_spacing

          %{
            observation
            | process: process,
              last_seen: now,
              counted_at: if(spaced, do: now, else: counted_at),
              count: observation.count + if(spaced, do: 1, else: 0)
          }
        else
          fresh(process, now)
        end

      _ ->
        fresh(process, now)
    end
  end

  defp fresh(process, now),
    do: %{process: process, count: 1, quiet_since: now, counted_at: now, last_seen: now}
end
