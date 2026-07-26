defmodule Canaryd.CLI do
  @moduledoc "escript entry: check | status | history [target] | install | uninstall"

  alias Canaryd.{Checker, Setup, Store, System, UnresponsiveMonitor}
  alias Canaryd.Apps.CleanClip

  def main(argv) do
    # launchd is an implementation detail: self-heal on every invocation
    unless argv == ["uninstall"], do: Setup.ensure_installed()
    dispatch(argv)
  end

  defp dispatch(["check"]) do
    case Checker.run() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:skipped_idle, idle, sys, apps} ->
        IO.puts(
          "idle #{idle}s, CleanClip probe skipped; system warnings: #{length(sys.warnings)}; " <>
            app_check_summary(apps)
        )

      {:checked, _idle, sys, cc, apps} ->
        IO.puts(
          "cleanclip: #{cc.probe} (#{cc.action}), failures=#{cc.failures}; system warnings: #{inspect(sys.warnings)}"
        )

        IO.puts(app_check_summary(apps))
    end
  end

  defp dispatch(["status"]) do
    idle = System.idle_seconds()

    Store.with_tables(fn state, events ->
      for target <- [:cleanclip, :system] do
        s = Store.get_state(state, target)

        IO.puts(
          "#{target}: #{s.status} | last_probe=#{s.last_probe} failures=#{s.consecutive_failures} " <>
            "| last_restart=#{fmt(s.last_restart_at)} | updated=#{fmt(s.updated_at)}"
        )
      end

      recent = Store.list_events(events, nil, 5)
      IO.puts("\nrecent events:")
      Enum.each(recent, &IO.puts("  #{fmt(&1.at)}  #{&1.target}  #{&1.type}"))

      monitor_state =
        Store.get_value(state, :unresponsive_apps, UnresponsiveMonitor.default_state())

      pending_apps = UnresponsiveMonitor.pending_apps(monitor_state)
      IO.puts("\nunresponsive apps: #{format_pending_apps(pending_apps)}")
    end)

    IO.puts("\ncleanclip process alive: #{CleanClip.process_alive?()}")
    IO.puts("user idle: #{idle}s")
  end

  defp dispatch(["history"]), do: dispatch(["history", "cleanclip"])

  defp dispatch(["history", target]) do
    Store.with_tables(fn _state, events ->
      events
      |> Store.list_events(history_target(target), 50)
      |> Enum.each(fn e ->
        details = Map.drop(e, [:target, :type, :at])

        IO.puts(
          "#{fmt(e.at)}  #{e.type}#{if map_size(details) > 0, do: "  #{inspect(details)}", else: ""}"
        )
      end)
    end)
  end

  defp dispatch(["install"]) do
    case Setup.install() do
      :ok -> IO.puts("launchd agent installed (#{Setup.label()})")
      {:error, err} -> IO.puts("install failed: #{err}")
    end
  end

  defp dispatch(["uninstall"]) do
    Setup.uninstall()
    IO.puts("launchd agent removed")
  end

  defp dispatch(_argv) do
    IO.puts("""
    canaryd - Mac health monitor

    usage:
      canaryd check              run one check round (launchd does this every 5 min)
      canaryd status             current health snapshot
      canaryd history [target]   event timeline (cleanclip, system, apps)
      canaryd install            (re)install the launchd agent (usually automatic)
      canaryd uninstall          remove the launchd agent
    """)
  end

  defp app_check_summary(%{status: :available, detected: detected, actions: actions}) do
    "unresponsive apps=#{detected}, actions=#{inspect(actions)}"
  end

  defp app_check_summary(%{status: :unavailable}) do
    "unresponsive app scan unavailable"
  end

  defp format_pending_apps([]), do: "none"

  defp format_pending_apps(apps) do
    Enum.map_join(apps, ", ", fn app -> "#{app.name} (PID #{app.pid})" end)
  end

  defp history_target("cleanclip"), do: :cleanclip
  defp history_target("system"), do: :system
  defp history_target("apps"), do: :apps
  defp history_target(_target), do: :unknown

  defp fmt(nil), do: "-"
  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
