defmodule Canaryd.StoreTest do
  use ExUnit.Case, async: false

  alias Canaryd.Store

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
end
