defmodule Canaryd.ReportStoreTest do
  use ExUnit.Case, async: false
  alias Canaryd.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "canaryd-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "reads all history, normalizes legacy records without modifying the file", %{dir: dir} do
    path = Path.join(dir, "events.dets")
    {:ok, table} = :dets.open_file(:report_fixture, file: String.to_charlist(path))

    for n <- 1..151 do
      :dets.insert(
        table,
        {n, %{at: ~U[2026-09-23 00:00:00Z], target: :self, type: :skipped_idle, idle_duration: 2}}
      )
    end

    :dets.close(table)
    before = File.read!(path)
    assert {:ok, events} = Store.read_events(dir)
    assert length(events) == 151
    assert Enum.all?(events, &(&1.idle_duration == 2000))
    assert File.read!(path) == before
    refute File.exists?(Path.join(dir, "state.dets"))
    refute File.exists?(Path.join(dir, "canaryd.lock"))
  end

  test "missing history is empty and corrupt history is preserved", %{dir: dir} do
    assert {:ok, []} = Store.read_events(Path.join(dir, "missing"))
    assert {:ok, []} = Store.read_events(dir)
    path = Path.join(dir, "events.dets")
    File.write!(path, "broken database")
    assert {:error, _} = Store.read_events(dir)
    assert File.read!(path) == "broken database"
    refute File.exists?(Path.join(dir, "canaryd.lock"))
  end

  test "respects an active writer lock", %{dir: dir} do
    path = Path.join(dir, "canaryd.lock")
    File.write!(path, "existing lock")
    assert {:error, :locked} = Store.read_events(dir)
    assert File.read!(path) == "existing lock"
  end
end
