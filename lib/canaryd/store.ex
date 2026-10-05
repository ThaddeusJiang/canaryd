defmodule Canaryd.Store do
  @moduledoc """
  DETS-backed persistent state.

  Two tables live under `~/Library/Application Support/canaryd/`:

    * `state.dets`  - latest state machine or monitor snapshot per target
      key: target name, value: map
    * `events.dets` - append-only event log
      key: {unix_usec, unique_integer}, value: event map

  Each CLI run opens the tables, does its work, syncs and closes.
  """

  alias Canaryd.{Duration, Paths}

  def dir, do: Paths.support_dir()

  @doc "Run `fun` with both tables open, guarded by an exclusive lockfile."
  def with_tables(fun, options \\ []) do
    dir = dir()
    lockfile = Path.join(dir, "canaryd.lock")
    lock_opener = Keyword.get(options, :lock_opener, &File.open/2)

    with :ok <- File.mkdir_p(dir) do
      case lock_opener.(lockfile, [:write, :exclusive]) do
        {:error, :eexist} ->
          {:error, :locked}

        {:error, reason} ->
          {:error, reason}

        {:ok, lock} ->
          try do
            with {:ok, state} <- open_table(:state, dir) do
              try do
                with {:ok, events} <- open_table(:events, dir) do
                  try do
                    fun.(state, events)
                  after
                    :dets.sync(events)
                    :dets.close(events)
                  end
                end
              after
                :dets.sync(state)
                :dets.close(state)
              end
            end
          after
            File.close(lock)
            File.rm(lockfile)
          end
      end
    end
  end

  defp open_table(name, dir) do
    path = String.to_charlist(Path.join(dir, "#{name}.dets"))

    case :dets.open_file(name, file: path, type: :set, repair: true) do
      {:ok, table} -> {:ok, table}
      {:error, {:file_error, _path, :enospc}} -> {:error, :enospc}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get latest state for a target, or a fresh default."
  def get_state(state_table, target) do
    case :dets.lookup(state_table, target) do
      [{^target, value}] -> value
      [] -> default_state()
    end
  end

  @doc "Get a stored value, or return the given default."
  def get_value(table, key, default) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  def put_state(state_table, target, value) do
    :dets.insert(state_table, {target, value})
  end

  def default_state do
    %{
      last_probe: nil,
      consecutive_failures: 0,
      last_restart_at: nil,
      status: :ok,
      updated_at: DateTime.utc_now()
    }
  end

  @doc "Append an event such as :hang_detected, :probe_fail, :restarted, or :blocked."
  def log_event(events_table, target, type, details \\ %{}) do
    now = DateTime.utc_now()
    key = {DateTime.to_unix(now, :microsecond), :erlang.unique_integer([:positive])}
    details = mark_duration_unit(type, details)

    event =
      Map.merge(details, %{
        target: target,
        type: type,
        at: now
      })

    :dets.insert(events_table, {key, event})
    event
  end

  @doc "All events, newest first, optionally filtered by target."
  def list_events(events_table, target \\ nil, limit \\ 100) do
    stored_entries = :dets.foldl(fn entry, events -> [entry | events] end, [], events_table)
    entries = Enum.map(stored_entries, &normalize_entry/1)

    stored_entries
    |> Enum.zip(entries)
    |> Enum.each(fn
      {entry, entry} -> :ok
      {_stored_entry, normalized_entry} -> :dets.insert(events_table, normalized_entry)
    end)

    entries
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.filter(fn e -> is_nil(target) or e.target == target end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc "Read all events without migrating or repairing the database. Missing history is empty."
  def read_events(directory \\ dir()) do
    path = Path.join(directory, "events.dets")

    if File.dir?(directory) do
      lockfile = Path.join(directory, "canaryd.lock")

      case File.open(lockfile, [:write, :exclusive]) do
        {:ok, lock} ->
          try do
            read_event_file(path)
          after
            File.close(lock)
            File.rm(lockfile)
          end

        {:error, :eexist} ->
          {:error, :locked}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case File.stat(directory) do
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :not_a_directory}
      end
    end
  end

  defp read_event_file(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}

      {:ok, _} ->
        case :dets.open_file(:canaryd_report_events,
               file: String.to_charlist(path),
               type: :set,
               access: :read,
               repair: false
             ) do
          {:ok, table} ->
            try do
              {:ok,
               :dets.foldl(fn {_key, event}, acc -> [normalize_event(event) | acc] end, [], table)}
            after
              :dets.close(table)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp mark_duration_unit(:skipped_idle, %{idle_duration: _duration} = details) do
    Map.put(details, :duration_unit, :millisecond)
  end

  defp mark_duration_unit(_type, details), do: details

  defp normalize_entry({key, event}), do: {key, normalize_event(event)}

  defp normalize_event(
         %{
           type: :skipped_idle,
           idle_duration: _duration,
           duration_unit: :millisecond
         } = event
       ),
       do: event

  defp normalize_event(%{type: :skipped_idle, idle_duration: duration} = event)
       when is_integer(duration) do
    event
    |> Map.put(:idle_duration, Duration.seconds(duration))
    |> Map.put(:duration_unit, :millisecond)
  end

  defp normalize_event(%{type: :skipped_idle, idle_seconds: duration} = event)
       when is_integer(duration) do
    event
    |> Map.delete(:idle_seconds)
    |> Map.put(:idle_duration, Duration.seconds(duration))
    |> Map.put(:duration_unit, :millisecond)
  end

  defp normalize_event(event), do: event
end
