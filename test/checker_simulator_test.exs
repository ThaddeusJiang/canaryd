defmodule Canaryd.CheckerSimulatorTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Checker, Duration, SimulatorMonitor, Store}

  defmodule SimulatorStub do
    def frontmost?, do: {:ok, Process.get(:simulator_foreground, false)}
    def active_automation_processes, do: {:ok, []}

    def shutdown(device) do
      send(self(), {:shutdown_requested, device.udid})
      :ok
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "canaryd-checker-simulator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    state_path = Path.join(root, "state.dets") |> String.to_charlist()
    events_path = Path.join(root, "events.dets") |> String.to_charlist()
    {:ok, state} = :dets.open_file(__MODULE__.State, file: state_path)
    {:ok, events} = :dets.open_file(__MODULE__.Events, file: events_path)
    Store.put_state(state, :idle_simulators, SimulatorMonitor.default_state())

    on_exit(fn ->
      :dets.close(state)
      :dets.close(events)
      File.rm_rf(root)
    end)

    %{state: state, events: events, state_path: state_path}
  end

  test "persists foreground activity seen during shutdown revalidation for later rounds", %{
    state: state,
    events: events,
    state_path: state_path
  } do
    device = device("3AB52C32-12FE-4D58-9971-1B831FA30057")
    Process.put(:simulator_foreground, true)
    before_observation = DateTime.utc_now()

    assert :shutdown_skipped =
             Checker.run_simulator_action(state, events, {:shutdown, device}, SimulatorStub)

    refute_received {:shutdown_requested, _}
    assert [%{reason: :simulator_foreground}] = Store.list_events(events, :simulators)

    :ok = :dets.sync(state)
    :ok = :dets.close(state)
    {:ok, ^state} = :dets.open_file(state, file: state_path)
    saved = Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())
    assert %DateTime{} = saved.last_foreground_at
    assert DateTime.compare(saved.last_foreground_at, before_observation) in [:eq, :gt]

    for minutes <- [5, 14] do
      now = Duration.add(saved.last_foreground_at, Duration.minutes(minutes))
      assert {_state, []} = SimulatorMonitor.evaluate(saved, [device], false, false, now)
    end

    eligible_at = Duration.add(saved.last_foreground_at, Duration.minutes(15))

    assert {_state, [{:shutdown, ^device}]} =
             SimulatorMonitor.evaluate(saved, [device], false, false, eligible_at)
  end

  test "foreground activity protects subsequent devices already queued in the same round", %{
    state: state,
    events: events
  } do
    first = device("3AB52C32-12FE-4D58-9971-1B831FA30057")
    second = device("2CB6293C-6DE6-46CC-9E3F-087EA247C771")
    Process.put(:simulator_foreground, true)

    assert :shutdown_skipped =
             Checker.run_simulator_action(state, events, {:shutdown, first}, SimulatorStub)

    Process.put(:simulator_foreground, false)

    assert :shutdown_skipped =
             Checker.run_simulator_action(state, events, {:shutdown, second}, SimulatorStub)

    refute_received {:shutdown_requested, _}
    assert [%{reason: :recent_activity} | _] = Store.list_events(events, :simulators)
  end

  defp device(udid) do
    %{
      udid: udid,
      name: "Test Simulator",
      runtime: "iOS",
      state: :booted,
      last_used_at: Duration.add(DateTime.utc_now(), -Duration.minutes(60))
    }
  end
end
