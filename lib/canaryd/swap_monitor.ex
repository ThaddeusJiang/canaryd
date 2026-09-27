defmodule Canaryd.SwapMonitor do
  @moduledoc """
  Correlates sustained global swap growth with the largest observed app RSS.

  The result deliberately says "related suspects" rather than attributing swap
  to one process. macOS exposes swap usage globally, not as a per-process cause.
  """

  alias Canaryd.{Duration, PolicyConfig}

  def default_state, do: %{observation: nil, alerts: %{}}

  def evaluate(state, usage, apps, now, policy \\ PolicyConfig.defaults()) do
    state = normalize_state(state, now)

    case usage do
      %{used_bytes: used_bytes} when used_bytes >= policy.swap_min_used * 1_024 * 1_024 ->
        observe(state, usage, apps, now, policy)

      _ ->
        {%{state | observation: nil}, []}
    end
  end

  defp observe(state, usage, apps, now, policy) do
    observation = next_observation(state.observation, usage, apps, now, policy)

    if alert?(observation, policy) and alert_allowed?(state, now, policy) do
      {%{state | observation: nil, alerts: Map.put(state.alerts, :swap, now)},
       [{:alert, usage, top_apps(apps)}]}
    else
      {%{state | observation: observation}, []}
    end
  end

  defp next_observation(nil, usage, apps, now, _policy),
    do: %{first: usage, last: usage, apps: apps, count: 1, last_seen: now, counted_at: now}

  defp next_observation(previous, usage, apps, now, policy) do
    gap = Duration.between(now, previous.last_seen)

    if gap >= 0 and gap <= policy.swap_max_gap and
         usage.used_bytes >= previous.last.used_bytes do
      counted_at = Map.get(previous, :counted_at, previous.last_seen)
      spaced = Duration.between(now, counted_at) >= policy.swap_min_spacing

      %{
        previous
        | last: usage,
          apps: apps,
          count: previous.count + if(spaced, do: 1, else: 0),
          last_seen: now
      }
      |> Map.put(:counted_at, if(spaced, do: now, else: counted_at))
    else
      next_observation(nil, usage, apps, now, policy)
    end
  end

  defp alert?(%{count: count, first: first, last: last}, policy) do
    count >= policy.swap_confirmations and
      last.used_bytes - first.used_bytes >= policy.swap_min_growth * 1_024 * 1_024
  end

  defp alert_allowed?(%{alerts: alerts}, now, policy) do
    case Map.get(alerts, :swap) do
      nil -> true
      last_alert -> Duration.between(now, last_alert) >= policy.swap_alert_cooldown
    end
  end

  defp top_apps(apps) do
    apps
    |> Enum.sort_by(& &1.rss_mb, :desc)
    |> Enum.take(3)
    |> Enum.map(&Map.take(&1, [:id, :name, :pid, :rss_mb, :cpu_percent]))
  end

  defp normalize_state(state, now) do
    alerts =
      state
      |> Map.get(:alerts, %{})
      |> Map.filter(fn {_key, at} -> Duration.between(now, at) < Duration.days(1) end)

    %{observation: Map.get(state, :observation), alerts: alerts}
  end
end
