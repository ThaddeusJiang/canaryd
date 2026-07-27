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

  @dir Path.expand("~/Library/Application Support/canaryd")
  @lockfile Path.join(@dir, "canaryd.lock")

  def dir, do: @dir

  @doc "Run `fun` with both tables open, guarded by an exclusive lockfile."
  def with_tables(fun) do
    File.mkdir_p!(@dir)

    case File.open(@lockfile, [:write, :exclusive]) do
      {:error, :eexist} ->
        {:error, :locked}

      {:ok, lock} ->
        try do
          {:ok, state} = open_table(:state)
          {:ok, events} = open_table(:events)

          try do
            fun.(state, events)
          after
            :dets.sync(state)
            :dets.sync(events)
            :dets.close(state)
            :dets.close(events)
          end
        after
          File.close(lock)
          File.rm(@lockfile)
        end
    end
  end

  defp open_table(name) do
    path = String.to_charlist(Path.join(@dir, "#{name}.dets"))

    case :dets.open_file(name, file: path, type: :set, repair: true) do
      {:ok, table} -> {:ok, table}
      {:error, {:needs_repair, _}} -> repair_and_open(name, path)
      {:error, _} -> repair_and_open(name, path)
    end
  end

  defp repair_and_open(name, path) do
    File.rm(Path.join(@dir, "#{name}.dets"))
    :dets.open_file(name, file: path, type: :set)
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
    events_table
    |> :dets.traverse(fn {_key, event} -> [event] end)
    |> Enum.filter(fn e -> is_nil(target) or e.target == target end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end
end
