defmodule Canaryd.CheckerCleanClipTest do
  use ExUnit.Case, async: false
  alias Canaryd.{Checker, Duration, Store}
  @now ~U[2026-09-17 00:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "canaryd-cleanclip-#{System.unique_integer([:positive])}")
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

  defp options(extras \\ []) do
    Keyword.merge(
      [
        now: @now,
        alive?: fn ->
          send(self(), :liveness)
          true
        end,
        starter: fn ->
          send(self(), :start)
          true
        end,
        probe: fn ->
          send(self(), :probe)
          :ok
        end,
        restarter: fn ->
          send(self(), :restart)
          true
        end,
        notifier: fn _, _ -> :ok end
      ],
      extras
    )
  end

  test "liveness runs each round while healthy functional probes have an independent cadence",
       ctx do
    assert %{probe: :ok} = Checker.check_cleanclip(ctx.state, ctx.events, options())
    assert_received :liveness
    assert_received :probe

    result =
      Checker.check_cleanclip(
        ctx.state,
        ctx.events,
        options(now: Duration.add(@now, Duration.minutes(5)))
      )

    assert result.probe == :skipped
    assert_received :liveness
    refute_received :probe

    assert %{probe: :ok} =
             Checker.check_cleanclip(
               ctx.state,
               ctx.events,
               options(now: Duration.add(@now, Duration.minutes(30)))
             )

    assert_received :probe
  end

  test "missing process starts and probes immediately even during probe cooldown", ctx do
    Checker.check_cleanclip(ctx.state, ctx.events, options())
    assert_received :probe

    assert %{probe: :ok} =
             Checker.check_cleanclip(ctx.state, ctx.events, options(alive?: fn -> false end))

    assert_received :start
    assert_received :probe
  end

  test "failed launch is recorded without touching the clipboard", ctx do
    result =
      Checker.check_cleanclip(
        ctx.state,
        ctx.events,
        options(alive?: fn -> false end, starter: fn -> false end)
      )

    assert result.probe == :fail
    refute_received :probe
    assert [%{type: :process_start_failed} | _] = Store.list_events(ctx.events, :cleanclip)
  end

  test "failed functional probes retry on the next check and keep recovery policy", ctx do
    Checker.check_cleanclip(ctx.state, ctx.events, options(probe: fn -> {:fail, :test} end))
    assert_received :restart

    result =
      Checker.check_cleanclip(
        ctx.state,
        ctx.events,
        options(now: Duration.add(@now, Duration.minutes(5)))
      )

    assert result.probe == :ok
    assert result.action == :recovered
  end

  test "repeated failed launches alert once without probing or a second restart", ctx do
    opts =
      options(
        alive?: fn -> false end,
        starter: fn -> false end,
        notifier: fn _, _ -> send(self(), :notified) end
      )

    for minute <- [0, 5, 10, 15] do
      Checker.check_cleanclip(
        ctx.state,
        ctx.events,
        Keyword.put(opts, :now, Duration.add(@now, Duration.minutes(minute)))
      )
    end

    assert_received :notified
    refute_received :notified
    refute_received :probe
    refute_received :restart
    assert Store.get_state(ctx.state, :cleanclip).consecutive_failures == 4
  end
end
