defmodule Canaryd.ReportTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Canaryd.{CLI, Report}

  test "summarizes recorded outcomes without counting nested cleanup bytes twice" do
    events = [
      %{
        at: ~U[2026-09-23 01:00:00Z],
        target: :builds,
        type: :cleanup_completed,
        reclaimed_bytes: 100,
        removed: 2,
        failures: 1,
        sccache: %{reclaimed_bytes: 40}
      },
      %{at: ~U[2026-09-22 01:00:00Z], target: :apps, type: :restarted},
      %{at: ~U[2026-09-22 02:00:00Z], target: :apps, type: :restart_failed},
      %{at: ~U[2026-09-22 03:00:00Z], target: :apps, type: :hang_detected}
    ]

    report = Report.build(events)
    assert report.summary.event_count == 4
    assert report.summary.recorded_reclaimed_bytes == 100
    assert report.summary.cleanup_failures == 1
    assert report.summary.successful_action_events == 1
    assert report.summary.failed_action_events == 1
    assert report.summary.events_by_target_and_type.apps.hang_detected == 1
    assert length(report.events) == 4
    assert Report.build(events, ~U[2026-09-23 00:00:00Z]).summary.event_count == 1
  end

  test "exports every event as JSON with UTC timestamps and arbitrary details" do
    events =
      for n <- 1..150,
          do: %{
            at: ~U[2026-09-23 01:00:00Z],
            target: :apps,
            type: :blocked,
            reason: {:error, :protected},
            name: "应用\n\"#{n}"
          }

    output =
      capture_io(fn -> CLI.main(["report", "--json"], report_reader: fn -> {:ok, events} end) end)

    decoded = :json.decode(output)
    assert length(decoded["events"]) == 150
    assert hd(decoded["events"])["at"] == "2026-09-23T01:00:00Z"
    assert decoded["summary"]["event_count"] == 150
  end

  test "empty history is explicit, malformed filters and locked reads are errors" do
    assert Report.build([]).summary.first_event_at == nil

    assert capture_io(fn -> CLI.main(["report"], report_reader: fn -> {:ok, []} end) end) =~
             "Recorded events: 0"

    assert capture_io(:stderr, fn ->
             assert {:error, _} =
                      CLI.main(["report", "--since", "yesterday"],
                        halt: fn 2 -> :ok end,
                        report_reader: fn -> flunk("invalid filter must not read") end
                      )
           end) =~ "ISO 8601"

    assert capture_io(:stderr, fn ->
             assert {:error, :locked} =
                      CLI.main(["report", "--json"],
                        halt: fn 2 -> :ok end,
                        report_reader: fn -> {:error, :locked} end
                      )
           end) =~ "locked"
  end
end
