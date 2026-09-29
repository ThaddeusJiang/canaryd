defmodule Canaryd.CheckerPressureTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Checker, Duration, Store}

  @now ~U[2026-09-27 00:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "canaryd-pressure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, state} =
      :dets.open_file(__MODULE__.State, file: String.to_charlist(Path.join(root, "state")))

    {:ok, events} =
      :dets.open_file(__MODULE__.Events, file: String.to_charlist(Path.join(root, "events")))

    on_exit(fn ->
      :dets.close(state)
      :dets.close(events)
      File.rm_rf!(root)
    end)

    %{state: state, events: events}
  end

  defp rounds(ctx, warnings, pressure_warnings) do
    for minute <- [0, 5, 10, 15] do
      Checker.record_system(
        ctx.state,
        ctx.events,
        %{warnings: warnings, pressure_warnings: pressure_warnings},
        now: Duration.add(@now, Duration.minutes(minute)),
        notifier: fn title, body -> send(self(), {:notified, title, body}) end
      )
    end
  end

  test "system health records pressure without sending a duplicate notification", ctx do
    rounds(ctx, ["load1 31.48 > 8.0 (10 cores)"], ["load1 31.48 > 8.0 (10 cores)"])
    refute_received {:notified, _, _}
    assert [%{type: :system_warn}] = Store.list_events(ctx.events, :system)
    assert Store.get_state(ctx.state, :system).status == :blocked
  end

  test "memory and unavailable sampling warnings remain visible", ctx do
    rounds(ctx, ["memory free 5%", "system load unavailable"], [])

    assert_received {:notified, "Mac Health",
                     "System degraded: memory free 5%; system load unavailable"}

    refute_received {:notified, _, _}
  end

  test "mixed pressure and unrelated warnings report only unrelated system failures", ctx do
    rounds(ctx, ["memory free 5%", "load1 31.48 > 8.0"], ["load1 31.48 > 8.0"])
    assert_received {:notified, "Mac Health", "System degraded: memory free 5%"}
    refute_received {:notified, _, _}
  end

  test "recovery still clears system failure state", ctx do
    rounds(ctx, ["load1 31.48 > 8.0"], ["load1 31.48 > 8.0"])

    Checker.record_system(ctx.state, ctx.events, %{warnings: [], pressure_warnings: []},
      now: Duration.add(@now, Duration.minutes(20))
    )

    assert Store.get_state(ctx.state, :system).status == :ok
    assert [%{type: :recovered}, %{type: :system_warn}] = Store.list_events(ctx.events, :system)
  end
end
