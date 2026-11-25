defmodule Canaryd.Report do
  @moduledoc "Summaries and portable exports of recorded events; no inferred check counts or savings."

  @successful [:restarted, :closed, :shutdown, :terminated]
  @failed [
    :restart_failed,
    :action_failed,
    :shutdown_failed,
    :termination_failed,
    :process_start_failed
  ]
  @cleanup [:cleanup_completed, :pressure_cleanup_completed, :emergency_cleanup_completed]

  def build(events, since \\ nil) do
    events =
      events
      |> Enum.filter(&(is_nil(since) or DateTime.compare(&1.at, since) != :lt))
      |> Enum.sort_by(& &1.at, {:asc, DateTime})

    cleanups = Enum.filter(events, &(&1.type in @cleanup))

    %{
      schema_version: 1,
      generated_at: DateTime.utc_now(),
      since: since,
      limitations: [
        "Event history is not a log of every check; total checks, uptime and success rates are unknown.",
        "Successful actions are recorded outcomes, not proof of lasting recovery or performance improvement.",
        "Reclaimed bytes are recorded artifact sizes, not measured free-disk change; nested cache totals are not added again."
      ],
      summary: %{
        event_count: length(events),
        first_event_at: timestamp(List.first(events)),
        last_event_at: timestamp(List.last(events)),
        successful_action_events: Enum.count(events, &(&1.type in @successful)),
        failed_action_events: Enum.count(events, &(&1.type in @failed)),
        cleanup_runs: length(cleanups),
        cleanup_failures: sum(cleanups, :failures),
        removed_directories: sum(cleanups, :removed),
        recorded_reclaimed_bytes: sum(cleanups, :reclaimed_bytes),
        events_by_target_and_type:
          events
          |> Enum.group_by(& &1.target)
          |> Map.new(fn {target, entries} ->
            {target, Enum.frequencies_by(entries, & &1.type)}
          end)
      },
      events: events
    }
  end

  def run(args, reader) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean, since: :string])

    with true <- rest == [] and invalid == [],
         {:ok, since} <- parse_since(opts[:since]),
         {:ok, events} <- reader.() do
      report = build(events, since)

      if opts[:json] do
        if Code.ensure_loaded?(:json) do
          IO.puts(:json.encode(json_value(report)))
        else
          error(:json_requires_otp_27_or_later)
        end
      else
        IO.puts("Recorded events: #{report.summary.event_count}")
        IO.puts("Successful action events: #{report.summary.successful_action_events}")
        IO.puts("Failed action events: #{report.summary.failed_action_events}")

        IO.puts(
          "Cleanup runs: #{report.summary.cleanup_runs}; failures: #{report.summary.cleanup_failures}"
        )

        IO.puts("Recorded reclaimed bytes: #{report.summary.recorded_reclaimed_bytes}")

        for {target, types} <- Enum.sort(report.summary.events_by_target_and_type),
            {type, count} <- Enum.sort(types) do
          IO.puts("  #{target}.#{type}: #{count}")
        end

        Enum.each(report.limitations, &IO.puts/1)
      end
    else
      false -> error(:invalid_report_arguments)
      {:error, reason} -> error(reason)
    end
  end

  defp parse_since(nil), do: {:ok, nil}

  defp parse_since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> {:ok, date}
      _ -> {:error, "--since requires an ISO 8601 timestamp with timezone"}
    end
  end

  defp error(reason) do
    IO.puts(:stderr, "report unavailable: #{inspect(reason)}")
    {:error, reason}
  end

  defp timestamp(nil), do: nil
  defp timestamp(event), do: event.at
  defp sum(events, key), do: Enum.reduce(events, 0, fn e, total -> total + Map.get(e, key, 0) end)

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_value(v)} end)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when value in [nil, true, false], do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value) when is_binary(value) or is_number(value), do: value
end
