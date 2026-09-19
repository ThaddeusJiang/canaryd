defmodule Canaryd.CheckerCodexTest do
  use ExUnit.Case, async: false
  alias Canaryd.{Checker, CodexProcessMonitor, Duration, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "canaryd-codex-#{System.unique_integer([:positive])}")
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

  defp target,
    do: %{
      id: {:node_repl, 43, "start"},
      kind: :node_repl,
      pid: 43,
      ppid: 100,
      name: "node_repl",
      cpu_time: 130,
      protection: nil
    }

  defp options(now, extras \\ []) do
    Keyword.merge(
      [
        now: Duration.minutes(now),
        scanner: fn -> {:ok, [target()]} end,
        idle_reader: fn -> 0 end,
        terminator: fn p ->
          send(self(), {:terminated, p.pid})
          :ok
        end,
        notifier: fn _ -> :ok end
      ],
      extras
    )
  end

  test "scheduled checks retain quiet hosts because original sessions cannot reconnect", ctx do
    for minute <- 0..5 do
      Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(minute * 5))
    end

    result = Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(30))
    assert result.actions == [:quiet]
    refute_received {:terminated, 43}
    assert [%{type: :quiet_retained} | _] = Store.list_events(ctx.events, :codex_processes)
  end

  test "dry run neither signals nor advances persisted observations or events", ctx do
    for minute <- 0..5 do
      Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(minute * 5))
    end

    before_state = Store.get_value(ctx.state, :idle_codex_processes, %{})
    before_events = Store.list_events(ctx.events, :codex_processes)

    result =
      Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(30, dry_run: true))

    assert [%{status: :quiet}] = result.processes
    refute_received {:terminated, _}
    assert Store.get_value(ctx.state, :idle_codex_processes, %{}) == before_state
    assert Store.list_events(ctx.events, :codex_processes) == before_events
  end

  test "reports protected helpers and clears observations after a failed scan", ctx do
    scanner = fn -> {:ok, [%{target() | protection: :working_children}]} end

    result =
      Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(0, scanner: scanner))

    assert [%{status: :protected, reason: :working_children}] = result.processes
    Checker.check_idle_codex_processes(ctx.state, ctx.events, 0, options(5))

    result =
      Checker.check_idle_codex_processes(
        ctx.state,
        ctx.events,
        0,
        options(10, scanner: fn -> {:error, :unavailable} end)
      )

    assert result.status == :unavailable

    assert Store.get_value(ctx.state, :idle_codex_processes, %{}) ==
             CodexProcessMonitor.default_state()

    refute_received {:terminated, _}
  end

  test "unknown MCP session activity stays protected even while the Mac is idle", ctx do
    adapter = %{target() | kind: :cua_driver_mcp}
    opts = [scanner: fn -> {:ok, [adapter]} end]

    for minute <- 0..5 do
      Checker.check_idle_codex_processes(
        ctx.state,
        ctx.events,
        Duration.minutes(30),
        options(minute * 5, opts)
      )
    end

    result =
      Checker.check_idle_codex_processes(
        ctx.state,
        ctx.events,
        Duration.minutes(30),
        options(30, opts)
      )

    assert result.actions == []
    assert [%{reason: :session_activity_unknown}] = result.processes
    refute_received {:terminated, _}
  end
end
