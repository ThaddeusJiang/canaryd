defmodule Canaryd.CLI do
  @moduledoc "escript entry: check | thermal-check | status | history [target] | install | uninstall"

  alias Canaryd.{Checker, Setup, Store, System, ThermalMonitor, UnresponsiveMonitor}
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
            "#{thermal_summary(sys)}; #{app_check_summary(apps)}"
        )

      {:checked, _idle, sys, cc, apps} ->
        IO.puts(
          "cleanclip: #{cc.probe} (#{cc.action}), failures=#{cc.failures}; " <>
            "system warnings: #{inspect(sys.warnings)}; #{thermal_summary(sys)}"
        )

        IO.puts(app_check_summary(apps))
    end
  end

  defp dispatch(["thermal-check"]) do
    case Checker.run_thermal() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:thermal_checked, system} ->
        IO.puts(thermal_summary(system))
    end
  end

  defp dispatch(["status"]) do
    idle = System.idle_duration()
    current_system = System.check()

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

      thermal_state =
        Store.get_value(state, :thermal_processes, ThermalMonitor.default_state())

      IO.puts("thermal suspects pending: #{map_size(thermal_state.observations)}")
    end)

    IO.puts("\ncleanclip process alive: #{CleanClip.process_alive?()}")
    IO.puts("user idle: #{idle}s")
    IO.puts(thermal_summary(current_system))
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
      :ok ->
        IO.puts("launchd agents installed (#{Setup.label()}, #{Setup.thermal_label()})")

      {:error, err} ->
        IO.puts("install failed: #{err}")
    end
  end

  defp dispatch(["uninstall"]) do
    Setup.uninstall()
    IO.puts("launchd agents removed")
  end

  defp dispatch(_argv) do
    IO.puts("""
    canaryd - Mac health monitor

    usage:
      canaryd check              run one check round (launchd does this every 5 min)
      canaryd thermal-check      run one thermal check (launchd does this every 1 min)
      canaryd status             current health snapshot
      canaryd history [target]   event timeline (cleanclip, system, thermal, apps)
      canaryd install            (re)install the launchd agents (usually automatic)
      canaryd uninstall          remove the launchd agents
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

  defp thermal_summary(%{thermal_pressure: false} = system) do
    "thermal pressure: normal; #{System.temperature_summary(system)}"
  end

  defp thermal_summary(%{hot_processes: []} = system) do
    "thermal pressure: high; #{System.temperature_summary(system)}; " <>
      "no process uses at least 20% CPU"
  end

  defp thermal_summary(%{hot_processes: processes} = system) do
    suspects =
      Enum.map_join(processes, ", ", fn process ->
        "#{process.name} (PID #{process.pid}, CPU #{process.cpu_percent}%)"
      end)

    "thermal pressure: high; #{System.temperature_summary(system)}; suspects: #{suspects}"
  end

  defp history_target("cleanclip"), do: :cleanclip
  defp history_target("system"), do: :system
  defp history_target("thermal"), do: :thermal
  defp history_target("apps"), do: :apps
  defp history_target(_target), do: :unknown

  defp fmt(nil), do: "-"
  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
