defmodule Canaryd.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.CLI

  test "formats UTC timestamps in local time with an explicit offset" do
    assert CLI.format_datetime(~U[2026-09-04 10:43:36Z], 9 * 60 * 60) ==
             "2026-09-04 19:43:36 UTC+09:00"

    assert CLI.format_datetime(~U[2026-09-04 10:43:36Z], -(3 * 60 + 30) * 60) ==
             "2026-09-04 07:13:36 UTC-03:30"
  end

  test "prints the version without installing the launchd agent" do
    start = fn -> flunk("version must not start background monitoring") end

    for command <- ["--version", "version"] do
      assert capture_io(fn -> CLI.main([command], start: start) end) == "canaryd 0.4.7\n"
    end
  end

  test "runs the build cleanup command through the CLI" do
    build_cleanup = fn ->
      send(self(), :build_cleanup_called)
      {:error, :locked}
    end

    assert capture_io(fn ->
             CLI.main(["clean"],
               start: fn -> flunk("clean must not start background monitoring") end,
               ensure_notification_helper: fn -> :ok end,
               build_cleanup: build_cleanup
             )
           end) == "another build cleanup is running, skipping\n"

    assert_received :build_cleanup_called
  end

  test "starts background monitoring only on explicit request" do
    start = fn ->
      send(self(), :started)
      :ok
    end

    assert capture_io(fn ->
             CLI.main(["start"], start: start)
           end) == "background monitoring started\n"

    assert_received :started
    refute_received :started
  end

  test "stops background monitoring without first starting it" do
    stop = fn ->
      send(self(), :stopped)
      :ok
    end

    assert capture_io(fn ->
             CLI.main(["stop"],
               stop: stop,
               start: fn -> flunk("stop must not start background monitoring") end
             )
           end) == "background monitoring stopped\n"

    assert_received :stopped
  end

  test "help and invalid commands do not start background monitoring" do
    for args <- [[], ["--help"], ["unknown"], ["start", "unexpected"]] do
      output =
        capture_io(fn ->
          CLI.main(args,
            start: fn -> flunk("help must not start background monitoring") end,
            ensure_notification_helper: fn -> flunk("help must not prepare notifications") end
          )
        end)

      assert output =~ "canaryd start"
      assert output =~ "canaryd stop"
      refute output =~ "canaryd install"
      refute output =~ "canaryd uninstall"
    end
  end

  test "reports startup failures without claiming monitoring started" do
    output =
      capture_io(fn ->
        CLI.main(["start"],
          start: fn -> {:error, {:notification_helper_install_failed, "compiler failed"}} end
        )
      end)

    assert output =~ "start failed:"
    assert output =~ "compiler failed"
    refute output =~ "monitoring started"
  end

  test "keeps published lifecycle command aliases" do
    for {command, option, result} <- [
          {"install", :start, "started"},
          {"uninstall", :stop, "stopped"}
        ] do
      callback = fn ->
        send(self(), {:lifecycle, command})
        :ok
      end

      assert capture_io(fn -> CLI.main([command], [{option, callback}]) end) ==
               "background monitoring #{result}\n"

      assert_received {:lifecycle, ^command}
    end
  end

  test "manual commands prepare notifications without starting background tasks" do
    for command <- ["clean", "check", "thermal-check", "reclaim"] do
      output =
        capture_io(fn ->
          CLI.main([command],
            start: fn -> flunk("manual commands must not start background tasks") end,
            ensure_notification_helper: fn -> {:error, :helper_unavailable} end,
            build_cleanup: fn -> flunk("must report setup failure before cleanup") end
          )
        end)

      assert output == "#{command} failed: :helper_unavailable\n"
    end
  end

  test "reclaim previews protected and quiet helpers without enabling background tasks" do
    reclaimer = fn options ->
      assert options == [dry_run: true]

      %{
        status: :available,
        detected: 3,
        protected: 1,
        actions: [],
        processes: [
          %{pid: 1, name: "node_repl", status: :detected, reason: nil, quiet_duration: 600_000},
          %{
            pid: 2,
            name: "node_repl",
            status: :protected,
            reason: :working_children,
            quiet_duration: 0
          },
          %{pid: 3, name: "node_repl", status: :quiet, reason: nil, quiet_duration: 0}
        ]
      }
    end

    output =
      capture_io(fn ->
        CLI.main(["reclaim", "--dry-run"],
          reclaimer: reclaimer,
          ensure_notification_helper: fn -> flunk("preview must not install helpers") end
        )
      end)

    assert output =~ "observing (10/30 min quiet)"
    assert output =~ "kept: has child processes"
    assert output =~ "kept: quiet, session ownership unknown"
  end

  test "reclaim uses the guarded policy and reports lock failures" do
    output =
      capture_io(fn ->
        CLI.main(["reclaim"],
          ensure_notification_helper: fn -> :ok end,
          reclaimer: fn options ->
            assert options == [dry_run: false]
            {:error, :locked}
          end
        )
      end)

    assert output =~ "another check is running"
  end
end
