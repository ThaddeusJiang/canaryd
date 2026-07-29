defmodule Canaryd.StoreTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Duration, Store}

  setup do
    path = Path.join(System.tmp_dir!(), "canaryd-store-test.dets")
    File.rm(path)

    {:ok, table} =
      :dets.open_file(:canaryd_store_test, file: String.to_charlist(path), type: :set)

    on_exit(fn ->
      :dets.close(table)
      File.rm(path)
    end)

    %{table: table}
  end

  test "lists every matching event", %{table: table} do
    Store.log_event(table, :thermal, :heat_alerted, %{name: "First"})
    Store.log_event(table, :thermal, :notification_test, %{name: "Second"})
    Store.log_event(table, :system, :system_warn, %{})

    events = Store.list_events(table, :thermal, 10)

    assert events |> Enum.map(& &1.type) |> MapSet.new() ==
             MapSet.new([:notification_test, :heat_alerted])
  end

  test "migrates legacy idle event durations to milliseconds", %{table: table} do
    at = ~U[2026-07-29 00:00:00Z]
    expected_duration = Duration.seconds(1_801)

    :dets.insert(table, {
      :legacy_key,
      %{target: :self, type: :skipped_idle, at: at, idle_seconds: 1_801}
    })

    assert [
             %{
               idle_duration: ^expected_duration,
               duration_unit: :millisecond
             } = event
           ] = Store.list_events(table, :self)

    refute Map.has_key?(event, :idle_seconds)

    assert [{:legacy_key, ^event}] = :dets.lookup(table, :legacy_key)
  end

  test "migrates unversioned idle duration values from the current branch", %{table: table} do
    at = ~U[2026-07-29 00:00:00Z]

    :dets.insert(table, {
      :unversioned_key,
      %{target: :self, type: :skipped_idle, at: at, idle_duration: 1_801}
    })

    assert [%{idle_duration: 1_801_000, duration_unit: :millisecond}] =
             Store.list_events(table, :self)
  end

  test "keeps versioned millisecond idle durations unchanged", %{table: table} do
    at = ~U[2026-07-29 00:00:00Z]

    event = %{
      target: :self,
      type: :skipped_idle,
      at: at,
      idle_duration: 1_801_000,
      duration_unit: :millisecond
    }

    :dets.insert(table, {:current_key, event})

    assert [^event] = Store.list_events(table, :self)
  end
end
